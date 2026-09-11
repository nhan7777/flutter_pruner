# Phase C Implementation Plan: Audit Readiness Boundary

**Status:** In Progress  
**Started:** 2026-09-05  
**Branch:** v3-shared-view-investigation

---

## Objectives

Enhance `L10nStaticReadinessResolver` to properly validate configuration ownership and compute complete mutation footprints before declaring families action-ready.

---

## Design Decisions

### Decision 1: Reuse L10nConfig vs L10nGenerationConfig

**Options:**
- A. Use existing `L10nConfig.load()` (simpler, already validates paths)
- B. Use `L10nGenerationConfig` + `DefaultL10nGenerationConfigLoader` (comprehensive, byte-perfect)
- C. Duplicate validation logic in resolver

**Choice:** **A - Use L10nConfig**

**Rationale:**
- `L10nStaticReadinessResolver` is *static* analysis - no Flutter execution, no generation
- `L10nConfig` already validates: arb-dir, template-arb-file, output paths, escapes
- `L10nGenerationConfig` is for the *evidence pipeline* (Stage 1) with byte-perfect capture
- Resolver needs config *structure*, not byte-level immutability
- Simpler: returns `L10nConfigValid | L10nConfigInvalid | L10nConfigAbsent`
- Already used by `ArbInventory.read()`

### Decision 2: Config Fingerprint Strategy

**Options:**
- A. Hash Flutter SDK + l10n.yaml content + arb-dir (requires Flutter execution)
- B. Hash l10n.yaml content only (static, deterministic)
- C. Use version string 'static-resolver-v2' (simplest)

**Choice:** **B - Hash l10n.yaml content only**

**Rationale:**
- Static resolver contract: "bounded static analysis only, no Flutter execution"
- Cannot call `flutter --version` without breaking contract
- Config content hash is sufficient for TOCTOU detection
- Executor will use full fingerprint (SDK + config + arb-dir) when running gen-l10n
- Format: `sha256:<hex>` or `absent` when l10n.yaml doesn't exist

### Decision 3: Generated Output Verification

**Options:**
- A. Verify all generated files exist (strict)
- B. Skip verification, only enumerate expected paths (permissive)
- C. Make it configurable

**Choice:** **B - Enumerate expected paths, don't require existence**

**Rationale:**
- Static resolver runs during *analysis*, before any generation
- Fresh clone may not have generated files yet
- Developer may have `.gitignore`d generated outputs
- Existence check belongs in *executor* preflight, not static readiness
- Resolver's job: compute *what would be mutated*, not verify it exists
- Add blocker if output-dir unreadable, but not if specific files absent

### Decision 4: Locale ARB Enumeration

**Options:**
- A. Use `ArbInventory.read()` (comprehensive, already exists)
- B. Simple `Directory.listSync` with `.arb` filter (lightweight)
- C. Just enumerate pattern `{basename}_{locale}.arb` (fragile)

**Choice:** **A - Use ArbInventory.read()**

**Rationale:**
- Already battle-tested in adapter
- Returns `ArbBlocker` list with structured reasons
- Handles malformed files, symlinks, escapes gracefully
- Consistent with adapter's existing ARB handling
- If inventory has blockers → add to scoped blockers, skip family

### Decision 5: Stale Output Detection

**Options:**
- A. Compare mtimes (ARB vs generated) (fragile, timezone issues)
- B. Check config fingerprint only (reliable)
- C. Skip for static resolver (defer to executor)

**Choice:** **C - Skip for static resolver**

**Rationale:**
- Stale detection requires comparing file timestamps or tracking last-gen fingerprint
- Static resolver has no persistent state (no "last known fingerprint")
- mtime comparison unreliable: git clone, touch, timezone, filesystem quirks
- Executor will detect staleness during preflight before mutation
- Resolver's contract: "can this family be mutated given current structure?"
- Not: "is current generated output fresh?"

---

## Implementation Tasks

### Task C.1: Config Loading and Validation ✅

**File:** `lib/src/adapters/l10n/l10n_static_readiness_resolver.dart`

**Changes:**
```dart
// Add at top
import 'l10n_config.dart';
import 'arb_inventory.dart';
import 'package:crypto/crypto.dart';
import 'dart:convert';

// In resolve() method, after filtering l10n nodes:
for (final entry in familyGroups.entries) {
  final familyId = entry.key;
  final nodes = entry.value;
  
  // Load config
  final configResult = L10nConfig.load(project);
  
  switch (configResult) {
    case L10nConfigAbsent():
      continue; // Skip family, config not applicable
    
    case L10nConfigInvalid(reason: final reason, location: final location):
      // Add scoped blocker to all nodes in family
      for (final node in nodes) {
        _addBlocker(node, 'l10nConfigInvalid:$reason');
      }
      continue;
    
    case L10nConfigValid(config: final config):
      // Proceed with config
  }
  
  // ... rest of logic
}
```

**Blocker codes to add:**
- `l10nConfigInvalid:*` - Config validation failed

**Tests:**
- Config absent → family skipped
- Config invalid → blocker added
- Config valid → proceeds

---

### Task C.2: ARB Inventory Integration ✅

**Changes:**
```dart
// After config validation passes:
final inventory = ArbInventory.read(project, config);

if (inventory.blockers.isNotEmpty) {
  // Add blockers to all nodes in family
  for (final blocker in inventory.blockers) {
    final reason = 'arbInventory:${blocker.reason}';
    if (blocker.affectedNodeIds.isNotEmpty) {
      for (final nodeId in blocker.affectedNodeIds) {
        final node = nodes.firstWhereOrNull((n) => n.id == nodeId);
        if (node != null) _addBlocker(node, reason);
      }
    } else {
      // Namespace-level blocker affects all nodes
      for (final node in nodes) {
        _addBlocker(node, reason);
      }
    }
  }
  continue;
}
```

**Tests:**
- ARB dir missing → blocker added
- Template not regular file → blocker added
- ARB outside project → blocker added
- Valid inventory → proceeds

---

### Task C.3: Config Fingerprint Computation ✅

**Changes:**
```dart
// After config + inventory validated:
final configFingerprint = _computeConfigFingerprint(config, project);

// Helper method:
String _computeConfigFingerprint(L10nConfig config, ProjectContext project) {
  final l10nYamlPath = p.join(project.root.path, 'l10n.yaml');
  final l10nYamlFile = File(l10nYamlPath);
  
  if (!l10nYamlFile.existsSync()) {
    return 'absent'; // flutter: generate: true, no l10n.yaml
  }
  
  try {
    final bytes = l10nYamlFile.readAsBytesSync();
    final hash = sha256.convert(bytes);
    return 'sha256:$hash';
  } on FileSystemException {
    return 'unreadable';
  }
}
```

**Tests:**
- l10n.yaml exists → sha256 hash
- l10n.yaml absent (flutter: generate) → 'absent'
- l10n.yaml unreadable → 'unreadable'

---

### Task C.4: Complete Mutation Footprint ✅

**Changes:**
```dart
// Build complete physical paths:
final physicalPaths = <String>{};

// 1. All ARB files from inventory
for (final key in inventory.keys) {
  final arbPath = project.relative(Uri.parse(key.origin.toString()).path);
  physicalPaths.add(arbPath);
}

// Also enumerate all locale ARBs (not just those with keys)
final arbDir = Directory(config.arbDir);
for (final entity in arbDir.listSync(followLinks: false)) {
  if (p.extension(entity.path).toLowerCase() == '.arb') {
    physicalPaths.add(project.relative(entity.path));
  }
}

// 2. Generated output files
physicalPaths.add(project.relative(config.generatedLibraryPath));

// Enumerate locale-specific generated files: {outputClass}_{locale}.dart
// Pattern: AppLocalizations_en.dart, AppLocalizations_es.dart, etc.
// We can't know exact locales statically, so enumerate existing:
final outputDir = Directory(config.outputDir);
if (outputDir.existsSync()) {
  final outputClass = config.outputClass;
  final pattern = RegExp('^${RegExp.escape(outputClass)}_[a-z]{2}(?:_[A-Z]{2})?\\.dart\$');
  
  for (final entity in outputDir.listSync(followLinks: false)) {
    if (pattern.hasMatch(p.basename(entity.path))) {
      physicalPaths.add(project.relative(entity.path));
    }
  }
}

// 3. Config file (read-only, but affects generation)
physicalPaths.add('l10n.yaml');

final footprint = MutationFootprint(
  findingIds: nodes.map((n) => n.id).toSet(),
  physicalPaths: physicalPaths,
  riskScope: ActionRiskScope.boundedFamily,
  familyId: familyId,
);
```

**Tests:**
- Footprint includes all ARBs (not just template)
- Footprint includes primary generated file
- Footprint includes locale-specific generated files
- Footprint includes l10n.yaml
- Footprint paths are project-relative

---

### Task C.5: Family Disjoint Verification ✅

**Changes:**
```dart
// After all families built, verify no path overlap:
final allFootprints = <String, MutationFootprint>{};
for (final entry in entries.entries) {
  final footprint = entry.value.mutationFootprint;
  allFootprints[footprint.familyId!] = footprint;
}

// Check disjoint:
final families = allFootprints.keys.toList();
for (var i = 0; i < families.length; i++) {
  for (var j = i + 1; j < families.length; j++) {
    final f1 = allFootprints[families[i]]!;
    final f2 = allFootprints[families[j]]!;
    final overlap = f1.physicalPaths.intersection(f2.physicalPaths);
    
    if (overlap.isNotEmpty) {
      // Families share paths → block both
      // This should never happen with proper config, but fail-closed
      for (final nodeId in f1.findingIds) {
        _addBlocker(nodeId, 'familyPathOverlap:${families[j]}');
      }
      for (final nodeId in f2.findingIds) {
        _addBlocker(nodeId, 'familyPathOverlap:${families[i]}');
      }
    }
  }
}
```

**Tests:**
- Two families, disjoint paths → both pass
- Two families, shared ARB dir → both blocked
- Single family → passes

---

### Task C.6: Integration Test ✅

**New file:** `test/adapters/l10n/l10n_static_readiness_integration_test.dart`

**Scenarios:**
1. Complete valid config → family ready
2. Missing l10n.yaml → family skipped
3. Invalid arb-dir → blocker added
4. Missing template → blocker added
5. Malformed ARB → blocker added
6. Config fingerprint correct format
7. Complete footprint includes all files
8. Multiple families disjoint → both ready

---

## Acceptance Criteria

- [ ] All existing tests pass
- [ ] New integration test covers happy path + failure modes
- [ ] Config fingerprint format: `sha256:<hex>` or `absent`
- [ ] Mutation footprint includes: ARBs + generated + config
- [ ] Families with any blocker → excluded from index
- [ ] Stable reason codes for all failure types
- [ ] No regression in V2 review-only mode

---

## Risk Assessment

**Low Risk:**
- Using existing `L10nConfig.load()` - already battle-tested
- Using existing `ArbInventory.read()` - already in adapter
- Config fingerprint computation - simple hash

**Medium Risk:**
- Generated file enumeration pattern matching - could miss edge cases
- Family disjoint check - assumes single config, may not handle multi-config repos

**Mitigation:**
- Comprehensive test coverage
- Fail-closed on any uncertainty
- Document assumptions in code comments

---

## Next: Phase D Dependencies

Phase C output used by Phase D:
- `configurationFingerprint` → used in preflight TOCTOU check
- Complete `physicalPaths` → used to know what to stage/journal
- Config validation → ensures executor has valid config before staging

---

## Notes

- Static resolver remains *static* - no Flutter execution, no generation
- Existence checks deferred to executor preflight
- Stale detection deferred to executor preflight
- This bridges analysis → mutation safely

# GSY Position-Preserving Normalization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Normalize GSY duplicate ARB members by retaining the last effective value at the first occurrence position so pinned `gen-l10n` output remains byte-exact.

**Architecture:** Replace the removal-only normalization authority with a v2 manifest that declares exact byte-copy operations plus exact removals. Every transform reads replacement bytes from the immutable original ARB, so the manifest contains no third-party source text; the applier verifies original hash, transform bounds, replacement hash, decoded-object equivalence, and zero duplicate decoded keys before installing anything.

**Tech Stack:** Dart, `package:test`, immutable byte snapshots, canonical JSON, pinned Flutter 3.44.1 `gen-l10n`.

**Spec:** `docs/superpowers/plans/2026-08-22-safe-l10n-removal-v3-1-stage-1.md`

## Global Constraints

- Preserve last-value JSON semantics and first-occurrence member order.
- Keep exact byte/mode baseline-output reconciliation; never accept semantic-only generated output.
- Do not embed third-party ARB source bytes in the normalization manifest.
- Reject unknown fields, invalid/overlapping target spans, out-of-bounds source spans, hash drift, semantic drift, and remaining duplicate decoded keys.
- Preserve unrelated dirty worktree changes and do not commit or push without separate authorization.

---

### Task 1: Define and consume normalization v2

**Files:**
- Modify: `benchmark/accuracy/src/l10n_mutation_manifest.dart`
- Modify: `benchmark/accuracy/src/corpus_mutation_evidence.dart`
- Test: `test/benchmark/accuracy/corpus_mutation_evidence_test.dart`
- Test: `test/benchmark/accuracy/l10n_mutation_manifest_test.dart`

**Interfaces:**
- Consumes: immutable original ARB bytes and the pinned normalization manifest.
- Produces: `L10nCopiedByteSpan` records and `L10nNormalizedArb.copiedByteSpans`, applied simultaneously with `removedByteSpans` against original bytes.

- [ ] **Step 1: Write the failing behavior test**

  Use `{"dup":"old","alive":"yes","dup":"kept"}\n` and declare one copy from the final member over the first member plus removal of the final member. Assert the installed bytes are exactly `{"dup":"kept","alive":"yes"}\n`, not merely decoded-object equivalent.

- [ ] **Step 2: Run the focused test and verify RED**

  Run: `/Users/nhan/fvm/versions/3.47.0/bin/dart test test/benchmark/accuracy/corpus_mutation_evidence_test.dart --name "installs position-preserving semantic normalization only after pub get"`

  Expected: compile/test failure because copy-span authority is not implemented.

- [ ] **Step 3: Implement the minimal strict contract and applier**

  Add immutable copy-span records with `start`, `endExclusive`, `sourceStart`, and `sourceEndExclusive`. Parse only schema/version v2, compare embedded and disk-loaded authority including every copy span, validate all target/source bounds, combine copies and removals in target order, and source every copied byte from the original immutable snapshot.

- [ ] **Step 4: Add malformed-authority tests**

  Mutate copy targets to overlap removals, source ranges to escape the original bytes, ordering to be noncanonical, and hashes to drift. Assert the disposable corpus view rejects before normalization is installed.

- [ ] **Step 5: Run both focused suites and verify GREEN**

  Run: `/Users/nhan/fvm/versions/3.47.0/bin/dart test test/benchmark/accuracy/corpus_mutation_evidence_test.dart test/benchmark/accuracy/l10n_mutation_manifest_test.dart`

  Expected: all tests pass.

### Task 2: Generate position-preserving transforms independently

**Files:**
- Modify: `benchmark/accuracy/build_l10n_mutation_readiness_manifest.dart`
- Test: `test/benchmark/accuracy/l10n_mutation_manifest_test.dart`

**Interfaces:**
- Consumes: pinned GSY Git blobs at `2b6c49008afc44b90fee869dedf8e59a86482953`.
- Produces: canonical `gsy-normalized-family-v2.json` with exact copy/removal spans and replacement hashes.

- [ ] **Step 1: Extend frozen artifact assertions before builder changes**

  Require schema `2`, version `gsy-normalized-family-v2`, copy spans for every changed ARB, no embedded source bytes, and the root overlay policy `apply-declared-byte-transforms`.

- [ ] **Step 2: Run the manifest test and verify RED**

  Run: `/Users/nhan/fvm/versions/3.47.0/bin/dart test test/benchmark/accuracy/l10n_mutation_manifest_test.dart`

  Expected: failure against the current v1 removal-only artifact.

- [ ] **Step 3: Implement the minimal independent builder algorithm**

  Group top-level members by decoded key. For each duplicate group, copy the exact final member bytes over the first member target and remove every later member, using original-source offsets. Apply all transforms simultaneously, then require decoded equality, zero duplicates, stable first-occurrence order, and exact replacement hashes.

- [ ] **Step 4: Run the manifest test against a generated disposable artifact**

  Generate into a private temporary directory using the retained corpus inputs, then compare canonical JSON and hashes before updating frozen files.

### Task 3: Rotate frozen normalization authority

**Files:**
- Create: `benchmark/accuracy/manifests/gsy-normalized-family-v2.json`
- Modify: `benchmark/accuracy/manifests/l10n-mutation-readiness-v1.json`
- Modify: `benchmark/accuracy/src/l10n_mutation_manifest.dart`
- Modify: `benchmark/accuracy/src/corpus_mutation_evidence.dart`
- Modify: `test/benchmark/accuracy/l10n_mutation_manifest_test.dart`
- Delete after successful verification: `benchmark/accuracy/manifests/gsy-normalized-family-v1.json`

**Interfaces:**
- Consumes: independently generated canonical v2 artifact.
- Produces: exact filename/SHA authority shared by the strict reader and disposable corpus loader.

- [ ] **Step 1: Regenerate both linked artifacts with the independent builder**

  Write to a private temporary output directory first. Require retained source repositories to remain clean and at their pinned SHAs.

- [ ] **Step 2: Review the artifact diff**

  Confirm only the GSY normalization link/policy changes in the root manifest, all four GSY ARBs have copy/removal transforms, and no raw ARB text or absolute path appears.

- [ ] **Step 3: Install the canonical v2 artifact and update both SHA constants**

  Copy only the independently verified canonical files through a scoped patch, remove v1 only after no live reference remains, and update exact frozen expectations.

- [ ] **Step 4: Verify parser and corpus-loader agreement**

  Run both focused suites and require tampered bytes, linked manifests, forged embedded objects, and malformed transforms to reject.

### Task 4: Prove baseline reproducibility and rerun GSY

**Files:**
- Verify: `benchmark/accuracy/manifests/gsy-normalized-family-v2.json`
- Produce outside repository: `/private/tmp/l10n-stage1-gsy-v6-2026-08-25.json`

**Interfaces:**
- Consumes: frozen normalization v2 and Flutter 3.44.1.
- Produces: byte-exact baseline generation evidence and a redaction-safe Stage 1 GSY corpus artifact.

- [ ] **Step 1: Run focused regression and production composition tests**

  Run the manifest, corpus evidence, output reconciler, snapshot revalidator, family preflight, and production composition suites.

- [ ] **Step 2: Run static verification**

  Run scoped `dart format -o none --set-exit-if-changed`, `dart analyze --fatal-infos`, and `git diff --check`.

- [ ] **Step 3: Reproduce committed generated outputs**

  Provision disposable GSY, apply v2 normalization, run pinned Flutter 3.44.1 `gen-l10n`, and require all generated output bytes/modes to match the pinned baseline.

- [ ] **Step 4: Run production GSY v6**

  Run the Stage 1 driver with `--family gsy`, retain the artifact outside the repository, calculate SHA-256, scan for paths/raw output/secrets, and verify the retained GSY repository remains clean at the exact pinned SHA.

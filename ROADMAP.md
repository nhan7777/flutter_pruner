# Roadmap

Flutter Pruner aims to identify unused Flutter and Dart resources without
overstating certainty. The roadmap prioritizes false-positive prevention,
reversible changes, and evidence that can be reviewed independently.

This document describes product direction, not a delivery schedule.

## Product principles

- **Fail closed.** Missing targets, unresolved references, dynamic runtime
  behavior, and unsupported edits must reduce confidence.
- **Prefer a small trustworthy result.** A precise `SAFE` set is more useful
  than a large list built on assumptions.
- **Keep analysis and mutation separate.** `scan` is observational; `apply`
  requires an explicit plan, verification, and quarantine.
- **Make claims auditable.** Findings, blockers, coverage, verification, and
  recovery state belong in structured reports.
- **Treat runtime evidence asymmetrically.** A trace can prove that something
  is used, but it cannot prove that something is unused.

## Current foundation

### Semantic graph and confidence model

- [x] Cross-domain graph for Dart declarations, libraries, assets, and exact
      duplicates
- [x] Per-target reachability with explicit build conditions
- [x] Four confidence tiers: `SAFE`, `HIGH`, `REVIEW`, and `PROTECTED`
- [x] Eight hard safety predicates for actionable findings
- [x] Scoped blockers for unresolved, dynamic, generated, and incomplete input
- [x] Stable adapter ownership and deterministic report identifiers

See [the graph model](doc/graph-model.md) and
[the confidence model](doc/confidence-model.md).

### Built-in analyzers

- [x] Dart libraries and top-level declarations
- [x] Exact Dart references and import/export reachability
- [x] Application entrypoints and `@pragma('vm:entry-point')`
- [x] Common callback-handle roots, including isolate and background-work
      registration APIs
- [x] Asset declarations, resolution variants, exact semantic references, and
      bounded constant-string evaluation
- [x] FlutterGen accessor provenance and generated-code uncertainty
- [x] SHA-256 exact duplicate groups as review-only findings

Member-level Dart findings are intentionally outside the current scope. The
tool may use member information to protect top-level owners, but it does not
propose deleting individual methods or fields.

### Apply, verification, and recovery

- [x] Dry-run planning and exact `--finding-id` selection
- [x] Dependency-closed, whole-run all-or-nothing apply
- [x] Project-local operation lock for mutating commands
- [x] Revisioned and checksummed quarantine manifest
- [x] Baseline-delta verification with bounded subprocess output and deadlines
- [x] Automatic recovery to the original run baseline when a later step fails
- [x] Manual rollback with verifier-backed terminal state
- [x] Regular-file byte restoration and POSIX permission restoration where
      available

The rollback contract does not include xattrs, ACLs, ownership, or hard-link
topology. See [the architecture](doc/architecture.md) for transaction and
filesystem boundaries.

### Reports and integrations

- [x] Human-readable terminal output
- [x] JSON schema v3 for CI and downstream tooling
- [x] Self-contained offline HTML reports
- [x] Coverage, blocker, verification, transaction, and recovery evidence
- [x] Linux, macOS, and Windows CI configuration

## Near-term priorities

### Asset analysis depth

- [ ] Inventory exact Flutter bundle entries per platform and flavor
- [ ] Distinguish source bytes, bundle-entry bytes, compressed bytes, and final
      artifact impact
- [ ] Expand known semantic asset sinks without turning unknown APIs into
      optimistic results
- [ ] Improve generated accessor provenance while preserving generated-output
      boundaries
- [ ] Model asset-family removal and resolution variants as one verified action
- [ ] Add reproducible, anonymized large-project fixtures for asset regressions

### Dart reachability depth

- [ ] Expand framework callback registries through explicit adapters or policy
- [ ] Improve conditional target modeling where the analyzer host selects only
      one branch
- [ ] Refine unresolved-reference scoping without weakening namespace-wide
      fallback behavior
- [ ] Add more fixtures for isolates, native callbacks, web interop, generated
      parts, extensions, and dynamic dispatch

### Release and operations

- [x] Document a stable migration policy for future report schemas
- [ ] Add release automation that verifies version, changelog, tag, archive,
      and hosted CI state without publishing automatically
- [x] Add reproducible performance benchmarks using public synthetic fixtures
      and document the comparison and redaction protocol
- [ ] Improve recovery diagnostics for unsupported filesystem capabilities

## Future adapters

Each adapter should remain independently reviewable and must fail closed at
unmodeled runtime boundaries.

### High-impact candidates

- [x] Routes: `go_router`
- [ ] Routes: `auto_route`
- [ ] Routes: named `Navigator` routes
- [x] Dependency injection: direct base-scope `GetIt` registrations and
      resolved lookups (review-only)
- [ ] Dependency injection: `Injectable`, `GetIt` scopes, generated wiring,
      and runtime/container-state APIs
- [x] Localization keys: ARB and current real-source `gen-l10n` accessors
      (review-only)

### Additional candidates

- [ ] Riverpod provider reachability
- [ ] Unused font weights and variants
- [ ] Code-generation provenance from inputs to generated outputs
- [ ] Android native resources with shrinker-aware boundaries
- [ ] Release-artifact size attribution

### Research topics

- [ ] Oversized-image detection
- [ ] Perceptual duplicate detection
- [ ] Positive runtime-use evidence from integration tests
- [ ] Whole-feature subtree analysis across domains

## Non-goals

- **Fully automatic cleanup.** Dynamic reachability makes some cases
  undecidable. Ambiguous findings remain review-only.
- **A general-purpose Dart linter.** Existing analyzer and lint tooling should
  continue to own style and local static diagnostics.
- **Unused dependency detection.** Dedicated dependency validators already
  cover this problem.
- **Near-term GUI or hosted service.** The CLI and machine-readable reports are
  the primary integration surface.
- **Binary-size promises from source bytes.** Release impact requires measuring
  the built artifact for the exact target.

## Contributing priorities

The most useful contributions are small fixtures that reproduce a real
false-positive risk, especially:

- dynamic asset paths;
- deep links and routes without an in-app caller;
- background and native callback registration;
- conditional imports and Dart defines;
- generated code with incomplete semantic resolution;
- filesystem interruption and rollback edge cases.

See [CONTRIBUTING.md](CONTRIBUTING.md) for development and review requirements.

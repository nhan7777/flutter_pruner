# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.6.0] - 2026-08-24

### Changed

- Batch each non-empty fixed-point apply round into one verification wave and
  atomically commit its ordered transactions after a single accepted candidate
  verification. The baseline, verification policy and command order, apply
  eligibility, rollback boundary, exit codes, and package-mode safety remain
  unchanged.
- Extend manifest V3 and JSON report v3 additively with immutable accepted-wave
  evidence and ordered transaction membership. Legacy manifests remain
  readable, accepted wave audit records survive rollback, and JSON v2 output
  remains byte-for-byte frozen.

### Added

- Add isolated `control-1x1`, `fanout-12x1`, and `chain-2plus-rounds` apply
  fixture generation plus an opt-in A/A and counterbalanced A/B admission
  harness. In the admitted macOS arm64 synthetic study, the 1x1 control was
  0.43% slower within its 4.91% noise threshold, while 12 units in one round
  improved by 67.52% and four units across two rounds improved by 28.97%.
  These results are a fixture-scoped admission claim, not a real-project or
  combined-optimization claim.

### Fixed

- Scope external-package closure blockers to the selected library closure, so
  auxiliary and test-only dependencies no longer downgrade unrelated
  application libraries while affected application and conditional callers
  continue to fail closed.

## [1.5.0] - 2026-08-22

### Added

- Added a machine-readable release-blocker registry and CI admission gate.
  Hosted Windows report-capability conformance is required for the retained
  release SHA; evidence-only checks cannot replace hosted admission, and
  skipped adversarial tests cannot satisfy that gate.

### Fixed

- Recognized exact localization-member uses in execution-selected path
  dependencies without admitting dependency sources as removal candidates;
  imports reachable only from dead selected source remain non-live.
- Parsed project-owned Dart sources at the language version declared by the
  project's SDK lower bound, preventing newer analyzer releases from rejecting
  valid `final` formal parameters during `init` and `scan`; unparseable sources
  continue to downgrade coverage conservatively.
- Bounded legacy JSON v2 compatibility projections before report staging,
  preserving accepted wire bytes while rejecting oversized fan-out without
  partial output.
- Replaced report staging, replacement, and cleanup authority with append-only
  native object/commit persistence. Scan and apply now reject occupied exact
  outputs without clobbering them, validate committed bytes before READY, and
  retain monotonic canonical apply evidence when a terminal export fails.
- Corrected the Windows NTFS conformance contract exposed by hosted CI: an
  existing directory or reparse leaf is a collision, a renamed retained
  directory remains object-bound instead of following a replacement path, and
  release evidence hashes use checkout-stable LF bytes on every runner.
- Documented target-exact configured and auxiliary graph contexts, retained
  usage hard gates, nested-package ownership, generated-artifact provenance,
  and the blocked-oracle boundary for read-only natural replay evidence.
- Classified standard Dart execution roots and exact local
  `Isolate.spawnUri` targets without granting actionability across unresolved,
  external, generated, or symlink boundaries.
- Treated ordinary Dart files under `lib/gen/` and `lib/generated/` as owned
  source unless their suffix or location proves generated provenance.
- Rechecked every hard safety predicate, including `notRetained`, at apply
  admission so stale or forged `SAFE` findings cannot enter a mutation plan.
- Preserved the primary report write or flush failure when sink close also
  fails, and retained the failed object role so canonical batch failures are
  not mislabeled as external-export warnings.

### Documentation

- Reworked the README into a short first-run workflow with prominent safety
  warnings, and moved modes, CI, apply, report, and recovery guidance into a
  dedicated operational guide. Core architecture and contribution material now
  stay in their focused documents.

## [1.4.0] - 2026-08-19

### Added

- Added review-only direct base-scope `GetIt` registration and lookup analysis,
  plus ARB/current real-source `gen-l10n` key and accessor analysis. Dynamic,
  runtime, and generated boundaries emit scoped blockers; neither adapter has
  an apply action.

### Changed

- Limited `go_router` and localization usage analysis to Dart libraries
  reachable from configured application targets when that closure is complete;
  incomplete entrypoints or conditional directives continue to fail closed.
- Resolved exact `go_router` navigation forwarded through local wrappers,
  static path getters/helpers, route redirects, query strings, and nested
  parent-child route retention.
- Preserved blockers that cannot attach to an inventoried node in JSON v3 and
  terminal warnings, including malformed or duplicate ARB input with zero
  findings.

### Documentation

- Documented the as-built V2 adapter boundaries and a SHA-pinned natural
  accuracy replay, including its external-oracle evidence boundary.

## [1.3.0] - 2026-08-18

### Added

- Added a `go_router` route analyzer that inventories declared routes,
  composes nested paths, and resolves path-based and named navigation through
  the analyzer element model.
- Route findings remain review-only. Dynamic locations and external route
  channels, including platform deep links and web URLs, fail closed with
  scoped blockers.

### Changed

- Reworked the interactive `init` wizard to always present all three analysis
  modes, keep the detected conservative default, and require an explicit choice
  for `package-internal`.
- Improved terminal hierarchy for configuration summaries, risk warnings, and
  next steps while preserving the same labels when ANSI styling is unavailable.

## [1.2.0] - 2026-08-18

### Changed

- Made JSON v3 output compact and lazy, cached stable blocker IDs across
  findings, deduplicated exact blocker facts before graph indexing, and changed
  blocker retention to a source-indexed work queue.
- Streamed quarantine SHA-256 integrity checks instead of allocating each
  complete file in memory.
- Made HIGH classification check its manual-risk allowlist explicitly and
  strengthened duplicate planning tests so review-only findings cannot enter a
  removal plan even if an upstream tier is malformed.
- Pinned the canonical formatter/analyzer CI job to Dart 3.13.0 while retaining
  moving-stable compatibility tests, and gave subprocess-heavy recovery tests
  enough isolation or time to remain reliable under concurrent suite load.

### Added

- Added a deterministic blocker-fan-out benchmark for JSON report construction,
  serialization time, and output size.
- Added a redacted three-project scan/dry-run safety replay and an executable
  median JSON-report overhead gate for release readiness.

### Documentation

- Added the version 1 project-configuration schema, coverage assertions, and
  mandatory verification contract.
- Added report-schema migration and V1 release-readiness policies.

## [1.1.0] - 2026-08-17

### Added

- Added deterministic synthetic performance-fixture generation, repeatable JSON
  benchmarks, and opt-in Dart-adapter subphase profiling.
- Exposed shared adapter services and the Dart analysis workspace for adapter
  authors that need to reuse project-level semantic state.

### Changed

- Reused one analyzer workspace across Dart and asset analysis and overlapped
  lint-inclusive CLI diagnostics with semantic graph construction.
- Indexed incoming graph edges and blockers, and cached target reachability
  until the next graph mutation.
- Grouped duplicate candidates by size before streaming SHA-256, streamed asset
  inventory hashing, reduced repeated path-policy filesystem calls, and cached
  diagnostic source metadata.
- Redacted benchmark project paths by default; local paths are emitted only
  after explicitly passing `--include-project-path`.

## [1.0.1] - 2026-08-17

### Changed

- Broadened analyzer compatibility across the supported Dart SDK range.
- Shortened the package description for clearer pub.dev search results.

### Documentation

- Added a copyable CLI walkthrough for pub.dev's Example tab.

## [1.0.0] - 2026-08-17

### Added

- Semantic graph analysis across Dart declarations, libraries, Flutter assets,
  and exact duplicate files.
- Four confidence tiers (`SAFE`, `HIGH`, `REVIEW`, and `PROTECTED`) governed by
  explicit coverage, reachability, blocker, protection, and action predicates.
- Three analysis modes:
  - `application` for a declared complete application boundary;
  - `package` for conservative review-only analysis;
  - `package-internal` for explicitly scoped local-package cleanup.
- Project initialization through `flutter_pruner init`, with explicit targets,
  public entrypoints, analysis mode, and verification commands.
- Dart analysis for libraries and top-level declarations, including imports,
  exports, parts, conditional-directive blockers, generated-code boundaries,
  callback roots, and unresolved-reference protection.
- Asset inventory from `pubspec.yaml`, resolution-variant grouping, semantic
  sink detection, bounded string evaluation, FlutterGen provenance, and dynamic
  asset blockers.
- SHA-256 exact duplicate detection as review-only findings.
- Exact apply selection with repeatable `--finding-id` values.
- Dependency-closed dry-run and apply planning.
- Revisioned, checksummed quarantine manifests with per-case, transaction,
  verification, selection, and recovery evidence.
- Whole-run rollback and manual `rollback <run-id>` support.
- Project-local operation locking for apply, rollback, and quarantine
  maintenance.
- Human terminal output, JSON schema v3, and self-contained offline HTML reports.
- Public adapter, graph, project, verification-policy, and report APIs.
- Cross-platform CI configuration for the supported Dart SDK floor and stable
  Linux, macOS, and Windows environments.

### Changed

- Apply is whole-run all-or-nothing. Internal atomic units remain visible for
  diagnosis, but a later failure restores every mutation from the run or marks
  the run `recoveryRequired` when restoration cannot be proven.
- Mutating commands reject active, ambiguous, corrupt, or recovery-required
  historical quarantine state before starting new work.
- Verification and import cleanup use argv-only managed subprocesses with
  deadlines, bounded output, and observed process-tree termination.
- Regular-file replacement uses staged displacement and no-replace publication
  instead of overwriting a concurrently recreated project path.
- Public collection-bearing value objects defensively snapshot caller-owned
  inputs. Constructors are non-`const` where copying is required.
- `AdapterRegistry.builtIn` is runtime immutable; custom adapter sets are passed
  explicitly to `AdapterRegistry.resolve`.
- `VerificationPolicy` is exported as part of the public API.
- Legacy `workspace`, `analysis.root_coverage`, `apply --safe`, and
  `apply --high` interfaces are rejected in favor of explicit analysis modes.

### Fixed

- Exact asset references are graph edges rather than unconditional roots, so
  unreachable Dart code does not keep an asset alive by itself.
- Generated and unresolved Dart units emit blockers instead of allowing an
  unsupported `SAFE` result.
- Dynamic dispatch, compound operators, index operations, equality, implicit
  protocols, and generated references retain plausible top-level owners.
- Conditional imports and exports fail closed when target-aware branch edges
  cannot be represented completely.
- Dependencies of blocked or protected nodes remain retained even when the
  source node itself remains reportable.
- Apply binds planning, snapshots, and execution to one immutable action plan,
  preventing late-discovered paths from entering a transaction.
- Exact-selection reports preserve truthful requested, planned, remaining, and
  recovered outcome counts.
- Baseline-red verification requires parser-bound, complete comparison evidence
  before mutation.
- Rollback validates captured bytes and POSIX permission bits where available
  before recording a verified terminal state.
- Interrupted apply and restore states preserve ambiguous working-copy evidence
  instead of overwriting or deleting it.
- `quarantine clean --all` validates every run before deleting any run.
- Windows path normalization, traversal checks, process output, and lock tests
  use platform-correct behavior.

### Compatibility and recovery boundaries

- The regular-file rollback contract covers captured bytes and POSIX permission
  bits where the platform exposes them. It does not preserve xattrs, ACLs,
  ownership (`uid`/`gid`), or hard-link topology.
- File flushing and same-filesystem rename/link operations do not provide a
  portable parent-directory `fsync` or a general filesystem transaction.
- A process that deliberately detaches before it can be observed remains
  outside the managed process-tree termination proof.
- `package-internal` cannot discover consumers outside the analyzed package.
- Custom runtime callback and asset registries require explicit modeling or
  project policy.

[Unreleased]: https://github.com/nhan7777/flutter_pruner/compare/v1.5.0...main
[1.5.0]: https://github.com/nhan7777/flutter_pruner/compare/v1.4.0...v1.5.0
[1.4.0]: https://github.com/nhan7777/flutter_pruner/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/nhan7777/flutter_pruner/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/nhan7777/flutter_pruner/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/nhan7777/flutter_pruner/compare/v1.0.1...v1.1.0
[1.0.1]: https://github.com/nhan7777/flutter_pruner/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/nhan7777/flutter_pruner/tree/v1.0.0

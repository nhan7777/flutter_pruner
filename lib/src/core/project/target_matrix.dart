import '../graph/build_condition.dart';
import '../graph/execution_context_identity.dart';

/// Provenance and completeness of the build targets used for reachability.
enum TargetMatrixStatus {
  /// The project owner explicitly declared the complete supported matrix.
  declaredComplete,

  /// A configuration exists, but it explicitly does not cover every target.
  declaredPartial,

  /// Flutter Pruner supplied a convenience default for exploratory scanning.
  inferredDefault,
}

/// The concrete build targets and the evidence that the list is complete.
class TargetMatrix {
  /// Creates a target matrix.
  ///
  /// Targets and issues are immutable snapshots. Coverage evidence must not
  /// drift when a configuration parser or API caller later reuses its lists.
  factory TargetMatrix({
    required List<BuildTarget> targets,
    required TargetMatrixStatus status,
    required String source,
    List<String> issues = const [],
  }) {
    final snapshots = targets.map(BuildTarget.snapshot).toList(growable: false);
    final contextIds = <String>{};
    for (final target in snapshots) {
      final contextId = configuredExecutionContextId(target.name);
      if (!contextIds.add(contextId)) {
        throw ArgumentError.value(
          targets,
          'targets',
          'Build targets must derive unique execution-context identities; '
              'duplicate $contextId.',
        );
      }
    }
    return TargetMatrix._(
      targets: List<BuildTarget>.unmodifiable(snapshots),
      status: status,
      source: source,
      issues: List<String>.unmodifiable(issues),
    );
  }

  const TargetMatrix._({
    required this.targets,
    required this.status,
    required this.source,
    required this.issues,
  });

  /// Creates an explicitly complete matrix supplied through the public API.
  factory TargetMatrix.declared(List<BuildTarget> targets) => TargetMatrix(
    targets: targets,
    status: TargetMatrixStatus.declaredComplete,
    source: 'api',
  );

  /// Concrete configurations evaluated by the graph.
  final List<BuildTarget> targets;

  /// Whether and how this matrix was declared.
  final TargetMatrixStatus status;

  /// User-facing provenance, normally a configuration file path.
  final String source;

  /// Reasons the matrix is incomplete or otherwise conservative.
  final List<String> issues;

  /// Whether the owner asserted that every supported target is represented.
  bool get isComplete => status == TargetMatrixStatus.declaredComplete;
}

/// How reachability roots for an application or package were established.
enum RootCoverageMode {
  /// Executable application entrypoints were explicitly declared.
  applicationEntrypoints,

  /// Public package entry libraries were explicitly declared.
  packagePublicApi,

  /// Public package roots bound a package-internal closed-world analysis.
  packageInternal,

  /// Flutter Pruner inferred likely roots without an owner completeness claim.
  inferred,
}

/// Provenance and completeness of graph roots.
class RootCoverage {
  /// Creates root coverage metadata.
  ///
  /// Entrypoints and issues are immutable snapshots. Root coverage can
  /// authorize `SAFE`, so caller mutation must not remove a root while leaving
  /// the completeness assertion unchanged.
  factory RootCoverage({
    required RootCoverageMode mode,
    required String source,
    bool? internalBoundaryComplete,
    bool? externalConsumersCovered,
    bool? complete,
    List<String> publicEntrypoints = const [],
    List<String> issues = const [],
  }) => RootCoverage._(
    mode: mode,
    internalBoundaryComplete: internalBoundaryComplete ?? complete ?? false,
    externalConsumersCovered: externalConsumersCovered ?? complete ?? false,
    source: source,
    publicEntrypoints: List<String>.unmodifiable(publicEntrypoints),
    issues: List<String>.unmodifiable(issues),
  );

  const RootCoverage._({
    required this.mode,
    required this.internalBoundaryComplete,
    required this.externalConsumersCovered,
    required this.source,
    required this.publicEntrypoints,
    required this.issues,
  });

  /// Creates complete application coverage for explicit API callers.
  factory RootCoverage.applicationApi() => const RootCoverage._(
    mode: RootCoverageMode.applicationEntrypoints,
    internalBoundaryComplete: true,
    externalConsumersCovered: true,
    source: 'api',
    publicEntrypoints: <String>[],
    issues: <String>[],
  );

  /// Root discovery strategy.
  final RootCoverageMode mode;

  /// Whether the configured roots cover the selected local analysis boundary.
  final bool internalBoundaryComplete;

  /// Whether consumers outside the selected project/package were analysed.
  final bool externalConsumersCovered;

  /// Whether both the local boundary and external consumer universe are closed.
  bool get complete => internalBoundaryComplete && externalConsumersCovered;

  /// User-facing provenance for this assertion.
  final String source;

  /// Public package entry libraries, relative to the project root.
  final List<String> publicEntrypoints;

  /// Reasons root coverage is incomplete.
  final List<String> issues;
}

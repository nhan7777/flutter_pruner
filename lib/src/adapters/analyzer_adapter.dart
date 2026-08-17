import '../core/graph/build_condition.dart';
import '../core/graph/edge.dart';
import '../core/graph/evidence.dart';
import '../core/graph/node.dart';
import '../core/graph/reachability_graph.dart';
import '../core/project/project_context.dart';
import 'adapter_report_definition.dart';
import 'dart/dart_adapter_profile.dart';
import 'dart/dart_analysis_workspace.dart';

/// Services whose lifetime spans every adapter in one project analysis pass.
class AdapterServices {
  /// Creates a service bundle.
  const AdapterServices({this.dartWorkspace, this.dartProfile});

  /// Shared semantic analyzer state, when a selected adapter needs Dart facts.
  final DartAnalysisWorkspace? dartWorkspace;

  /// Optional fine-grained Dart adapter timings for benchmark runs.
  final DartAdapterProfile? dartProfile;
}

/// The plugin contract every analyzer adapter implements.
///
/// An adapter teaches the engine about one domain — assets, routes, dependency
/// injection, localization. The core engine knows nothing about those domains;
/// it only builds and queries a graph. That separation is what lets a
/// contributor add a new capability without touching the engine.
///
/// ## The shape of every adapter
///
/// 1. read the project
/// 2. add nodes for things that could be unused
/// 3. add edges for references that keep them alive
/// 4. add roots for entry points, protections for untouchables, and blockers
///    for anything unresolved
///
/// ## Example
///
/// ```dart
/// class MyAdapter extends AnalyzerAdapter {
///   @override
///   String get id => 'my_domain';
///
///   @override
///   String get name => 'My domain analyzer';
///
///   @override
///   Future<void> analyze(ProjectContext project, GraphBuilder graph) async {
///     graph.addNode(GraphNode(
///       id: 'mydomain:${thing.name}',
///       kind: NodeKind.declaration,
///       origin: thing.file.uri,
///     ));
///   }
/// }
/// ```
///
/// See `doc/contributing/how-to-add-adapter.md` for the full walkthrough, and
/// `doc/flutter-facts.md` for verified framework behaviour you will need.
abstract class AnalyzerAdapter {
  /// Creates an adapter.
  const AnalyzerAdapter();

  /// Stable identifier, lowercase snake_case — for example `assets`.
  ///
  /// Used as the node id scheme, as the `producer` on evidence, and in
  /// configuration to enable or disable this adapter. Changing it is breaking.
  String get id;

  /// Human-readable name shown in progress output.
  String get name;

  /// Presentation metadata for findings and measurements this adapter owns.
  ///
  /// Adapters without specialized report output receive an empty catalog whose
  /// identity follows their current [id] and [name].
  AdapterReportDefinition get reportDefinition =>
      AdapterReportDefinition(adapterId: id, displayName: name);

  /// Node-id schemes whose findings belong to this adapter.
  ///
  /// Most adapters use their id directly. Override when the stable graph
  /// scheme is singular or otherwise differs from the CLI adapter id.
  Set<String> get findingNodeSchemes => {id};

  /// Ids of adapters that must run before this one.
  ///
  /// Prefer an empty list. Adapters may add edges pointing at nodes that do not
  /// exist yet, so ordering is usually unnecessary — and independent adapters
  /// are easier to test and to review. Declare a dependency only when you must
  /// *read* another adapter's nodes.
  List<String> get dependsOn => const [];

  /// Whether this adapter applies to [project].
  ///
  /// Return `false` to skip cheaply — for instance a `go_router` adapter when
  /// the project has no `go_router` dependency. Skipping is not a failure.
  bool appliesTo(ProjectContext project) => true;

  /// Analyses [project], contributing to the graph through [graph].
  ///
  /// Throwing aborts the scan, so prefer recording a [Blocker] over throwing
  /// when input is merely unexpected: an unparseable file should lower
  /// confidence, not abandon the run.
  Future<void> analyze(ProjectContext project, GraphBuilder graph);

  /// Analyses [project] with services shared across the current adapter pass.
  ///
  /// Existing third-party adapters only need to implement [analyze]. Semantic
  /// adapters can override this hook to reuse expensive project-level state.
  Future<void> analyzeWithServices(
    ProjectContext project,
    GraphBuilder graph,
    AdapterServices services,
  ) => analyze(project, graph);
}

/// The write-side API adapters use to contribute to the graph.
///
/// Deliberately narrower than [ReachabilityGraph]: adapters add facts, and only
/// the engine queries reachability. That keeps adapters from making decisions
/// that need whole-graph knowledge they do not have.
class GraphBuilder {
  /// Wraps [_graph] for use by the adapter identified as [producerId].
  GraphBuilder(this._graph, this.producerId);

  final ReachabilityGraph _graph;

  /// The adapter id attributed to everything added through this builder.
  final String producerId;

  /// Adds a node. Idempotent per node id.
  void addNode(GraphNode node) => _graph.addNode(node, producer: producerId);

  /// Adds an edge. Endpoints need not exist yet.
  void addEdge(GraphEdge edge) => _graph.addEdge(edge);

  /// Convenience for the common "this references that" case.
  void addReference({
    required String from,
    required String to,
    required EdgeKind kind,
    required Evidence evidence,
    BuildCondition condition = BuildCondition.unconditional,
  }) {
    _graph.addEdge(
      GraphEdge(
        from: from,
        to: to,
        kind: kind,
        evidence: evidence,
        condition: condition,
      ),
    );
  }

  /// Registers [nodeId] as an entry point.
  ///
  /// Be generous. A missing root produces a confident, wrong deletion; an extra
  /// root only produces a missed cleanup opportunity.
  void addRoot(
    String nodeId, {
    required String reason,
    BuildCondition condition = BuildCondition.unconditional,
  }) {
    _graph.addRoot(nodeId, reason: reason, condition: condition);
  }

  /// Marks [nodeId] as never removable.
  ///
  /// Protection outranks every other signal, including a complete absence of
  /// references.
  void protect(String nodeId, {required String reason}) {
    _graph.protect(nodeId, reason: reason, producer: producerId);
  }

  /// Records an unresolved dynamic construct that could address nodes.
  ///
  /// Set [affectedNamespace] when the construct is bounded — for example
  /// `assets/flags/` for `Image.asset('assets/flags/$code.png')`. A blocker with
  /// no namespace and no node ids addresses the **entire** graph and downgrades
  /// every finding in the run, so scope it whenever you can.
  void addBlocker({
    required String reason,
    String? location,
    String? sourceNodeId,
    String? affectedNamespace,
    Set<String> affectedNodeIds = const {},
  }) {
    _graph.addBlocker(
      Blocker(
        producer: producerId,
        reason: reason,
        location: location,
        sourceNodeId: sourceNodeId,
        affectedNamespace: affectedNamespace,
        affectedNodeIds: affectedNodeIds,
      ),
    );
  }

  /// Builds an [Evidence] record attributed to this adapter.
  Evidence evidence({
    required EvidenceKind kind,
    required String description,
    bool exact = false,
    String? location,
  }) {
    return Evidence(
      kind: kind,
      producer: producerId,
      description: description,
      exact: exact,
      location: location,
    );
  }
}

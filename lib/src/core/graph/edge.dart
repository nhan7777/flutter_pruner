import 'build_condition.dart';
import 'evidence.dart';

/// Graph edge kinds.
///
/// An edge means "the source keeps the target alive". Adapters add edge kinds
/// for the relationships they understand.
enum EdgeKind {
  /// A Dart library imports or exports another.
  imports,

  /// A declaration references another declaration.
  references,

  /// Code loads an asset.
  loadsAsset,

  /// Code *may* load an asset, based on a partially-resolved pattern.
  ///
  /// Protects the target but is never exact enough to authorize deletion.
  mayLoadAsset,

  /// An asset bundles a resolution variant such as `2.0x/logo.png`.
  bundlesVariant,

  /// A generated artifact was produced from a source input.
  generatedFrom,

  /// A generated accessor stands for an underlying resource.
  accessorFor,

  /// Code navigates to a route.
  navigatesTo,

  /// Code registers a dependency-injection entry.
  registers,

  /// Code resolves a dependency-injection entry.
  resolves,

  /// Code uses a pub dependency.
  usesDependency,

  /// Code crosses into native code (platform channel, FFI symbol).
  callsNative,

  /// A keep rule or annotation protects the target.
  protects,
}

/// A directed edge in the reachability graph.
///
/// Edges are value objects: identical `(from, to, kind, condition)` tuples are
/// the same edge. The [evidence] explains why the edge exists and bounds how
/// confident a verdict derived from it may be.
class GraphEdge {
  /// Creates a graph edge.
  const GraphEdge({
    required this.from,
    required this.to,
    required this.kind,
    required this.evidence,
    this.condition = BuildCondition.unconditional,
  });

  /// Source node id.
  final String from;

  /// Target node id — the node kept alive by this edge.
  final String to;

  /// The relationship this edge represents.
  final EdgeKind kind;

  /// Why this edge exists.
  final Evidence evidence;

  /// The build configurations under which this edge applies.
  final BuildCondition condition;

  /// Whether this edge can contribute to a `SAFE` verdict.
  ///
  /// Inexact edges still make a target reachable — they just cannot be used to
  /// argue that something is definitively unreachable.
  bool get isExact => evidence.exact;

  @override
  bool operator ==(Object other) =>
      other is GraphEdge &&
      other.from == from &&
      other.to == to &&
      other.kind == kind &&
      other.condition == condition;

  @override
  int get hashCode => Object.hash(from, to, kind, condition);

  @override
  String toString() => '$from --[${kind.name}]--> $to';
}

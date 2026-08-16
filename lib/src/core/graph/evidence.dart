/// How strong a piece of evidence is, and where it came from.
///
/// Every edge carries [Evidence] so findings can explain *why* the tool
/// believes something. "No reference found" is never sufficient on its own —
/// reports must show what was actually checked.
enum EvidenceKind {
  /// A resolved semantic reference from the Dart analyzer. Strongest form.
  semanticReference,

  /// A compile-time-constant string that resolved to exactly one target.
  constString,

  /// A finite set of constant strings (for example a `const` list of codes).
  finiteStringSet,

  /// A partially-known string, for example `'assets/flags/$code.png'`.
  ///
  /// Matches a pattern rather than one target, so it can only *protect*
  /// candidates, never authorize deletion.
  symbolicPattern,

  /// A generated accessor mapped back to its source (for example FlutterGen).
  generatedAccessor,

  /// Declared in project configuration (`pubspec.yaml`, `l10n.yaml`, manifest).
  configuration,

  /// A user-supplied keep rule.
  userKeepRule,

  /// An annotation such as `@pragma('vm:entry-point')`.
  annotation,

  /// Observed during an instrumented run.
  ///
  /// Asymmetric: observing use proves "used"; not observing proves nothing.
  runtimeObservation,

  /// Corroborated by an external tool (R8, APK Analyzer, `--analyze-size`).
  externalTool,
}

/// Why the graph contains a particular edge.
class Evidence {
  /// Creates an evidence record.
  const Evidence({
    required this.kind,
    required this.producer,
    required this.description,
    this.exact = false,
    this.location,
  });

  /// The kind of evidence.
  final EvidenceKind kind;

  /// The adapter id that produced it, for example `assets` or `dart`.
  final String producer;

  /// Human-readable explanation shown in `explain` output.
  final String description;

  /// Whether this pins down exactly one target.
  ///
  /// Only exact evidence can support a `SAFE` verdict. Pattern and runtime
  /// evidence are inexact by nature.
  final bool exact;

  /// Source location, when the evidence came from a specific place in a file.
  final String? location;

  @override
  String toString() => 'Evidence(${kind.name} from $producer)';
}

/// An unresolved dynamic construct that prevents a confident verdict.
///
/// Blockers are the safety mechanism against the tool's worst failure mode:
/// deleting something reached in a way static analysis cannot see. A blocker
/// says "there is a code path here I could not resolve, and it might address
/// these nodes".
///
/// Examples: an asset path built from a server response, a `get_it` lookup with
/// a runtime `instanceName`, an FFI symbol looked up by string.
class Blocker {
  /// Creates a blocker.
  factory Blocker({
    required String producer,
    required String reason,
    String? location,
    String? sourceNodeId,
    String? affectedNamespace,
    Set<String> affectedNodeIds = const {},
  }) => Blocker._(
    producer: producer,
    reason: reason,
    location: location,
    sourceNodeId: sourceNodeId,
    affectedNamespace: affectedNamespace,
    affectedNodeIds: Set.unmodifiable(affectedNodeIds),
  );

  const Blocker._({
    required this.producer,
    required this.reason,
    required this.location,
    required this.sourceNodeId,
    required this.affectedNamespace,
    required this.affectedNodeIds,
  });

  /// The adapter id that raised this blocker.
  final String producer;

  /// Why the construct could not be resolved.
  final String reason;

  /// Where in the source it occurs, when a precise location is known.
  ///
  /// Always supply this when you have it: it is the difference between a user
  /// being able to inspect the call site and decide, and being told only that
  /// something somewhere is unresolvable.
  final String? location;

  /// Caller whose reachability activates this blocker, when known.
  final String? sourceNodeId;

  /// Namespace prefix this blocker could address, for example `assets/flags/`.
  ///
  /// When set, every node under this namespace must be downgraded.
  final String? affectedNamespace;

  /// Specific nodes this blocker could address, when they are known.
  final Set<String> affectedNodeIds;

  /// Whether this blocker is unscoped, and therefore addresses every node.
  bool get isUnscoped => affectedNamespace == null && affectedNodeIds.isEmpty;

  /// Whether this blocker could plausibly address [nodeId].
  ///
  /// An unscoped blocker addresses **everything**. That direction is
  /// deliberate: an adapter author who records a blocker but forgets to scope
  /// it gets an over-broad downgrade they will notice immediately, rather than
  /// silent zero protection they will not. Failing loudly beats failing safe-
  /// looking.
  ///
  /// Scope with [affectedNamespace] or [affectedNodeIds] whenever the construct
  /// is bounded, since an unscoped blocker downgrades the entire run.
  bool couldAddress(String nodeId) {
    if (affectedNodeIds.contains(nodeId)) return true;
    final namespace = affectedNamespace;
    if (namespace == null) return affectedNodeIds.isEmpty;
    if (nodeId.startsWith(namespace)) return true;

    // Adapter-facing namespaces are commonly logical paths (`assets/icons/`),
    // while graph ids carry an owner prefix (`asset:app/assets/icons/...`).
    // Match only at a path boundary instead of the previous arbitrary
    // substring match, which could make `icons/` affect `old_icons/`.
    return !namespace.contains(':') && nodeId.contains('/$namespace');
  }

  @override
  String toString() =>
      'Blocker($reason${location == null ? '' : ' at $location'})';
}

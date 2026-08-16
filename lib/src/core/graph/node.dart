import 'dart:collection';

/// Graph node kinds.
///
/// A node is anything that can potentially be unused. Adapters contribute
/// nodes of the kinds they understand — the core engine treats them uniformly.
///
/// Contributors adding a new adapter usually add a new [NodeKind] value here.
enum NodeKind {
  /// A package in the project or workspace.
  package,

  /// A Dart library (one `.dart` file).
  dartLibrary,

  /// A declaration inside a Dart library (class, function, variable, member).
  declaration,

  /// An analyzer-reported unused construct not yet modeled as an editable
  /// graph declaration, such as an import, local variable, field, or parameter.
  analyzerDiagnostic,

  /// A bundled Flutter asset, addressed by its logical key.
  asset,

  /// A resolution variant of an asset (for example `2.0x/logo.png`).
  ///
  /// Variants have no logical key of their own; they are always reached
  /// through their parent [asset]. Never report a variant as unused on its own.
  assetVariant,

  /// A file emitted by a code generator.
  generatedArtifact,

  /// A localization message key from an ARB file.
  localizationKey,

  /// A declared route path.
  route,

  /// A dependency-injection registration.
  diRegistration,

  /// A pub dependency.
  dependency,

  /// A platform-native resource (Android `res/`, iOS asset catalog entry).
  nativeResource,

  /// A program entry point.
  entrypoint,

  /// A group of byte-identical files.
  duplicateGroup,
}

/// A node in the reachability graph.
///
/// Nodes are value objects identified by [id]. Two nodes with the same [id]
/// are the same node; adding a node twice is idempotent.
///
/// ## Node ID convention
///
/// IDs must be stable across runs and unique across adapters. Use a
/// `<scheme>:<package>/<path>#<symbol>` shape:
///
/// ```text
/// dart:app/lib/home/home_page.dart#HomePage
/// asset:app/assets/images/logo.webp
/// route:app:/product/:id
/// di:app:PaymentService@stripe:prod
/// dep:app:package:dio
/// ```
///
/// Prefixing with the adapter's scheme prevents ID collisions between adapters.
class GraphNode {
  /// Creates a graph node.
  factory GraphNode({
    required String id,
    required NodeKind kind,
    required Uri origin,
    int? sizeBytes,
    String? sha256,
    String? displayName,
    Map<String, Object?> metadata = const {},
  }) => GraphNode._(
    id: id,
    kind: kind,
    origin: origin,
    sizeBytes: sizeBytes,
    sha256: sha256,
    displayName: displayName,
    metadata: _snapshotMetadata(metadata),
  );

  const GraphNode._({
    required this.id,
    required this.kind,
    required this.origin,
    required this.sizeBytes,
    required this.sha256,
    required this.displayName,
    required this.metadata,
  });

  /// Stable canonical identifier. See the class docs for the convention.
  final String id;

  /// What kind of thing this node represents.
  final NodeKind kind;

  /// Where this node came from on disk.
  ///
  /// For assets this is the file; for declarations it is the containing
  /// library. Used to render findings and to locate files for removal.
  final Uri origin;

  /// Size on disk in bytes, when meaningful.
  ///
  /// Only set this for nodes backed by a real file. Note that for assets with
  /// build-time transformers the bundled size differs from the source size, so
  /// never present this as a binary-size saving.
  final int? sizeBytes;

  /// Hex-encoded SHA-256 of the file contents, when computed.
  final String? sha256;

  /// Short human-readable label for reports, when [id] is not friendly enough.
  final String? displayName;

  /// Adapter-specific extra data.
  ///
  /// The core engine never interprets this. Keep values JSON-encodable so
  /// reports can serialize them.
  final Map<String, Object?> metadata;

  /// Label to show in reports.
  String get label => displayName ?? id;

  @override
  bool operator ==(Object other) => other is GraphNode && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'GraphNode($id)';
}

Map<String, Object?> _snapshotMetadata(Map<String, Object?> metadata) =>
    _snapshotMetadataMap(metadata, HashSet<Object>.identity(), 'metadata');

Map<String, Object?> _snapshotMetadataMap(
  Map<Object?, Object?> value,
  Set<Object> active,
  String path,
) {
  if (!active.add(value)) {
    throw ArgumentError('GraphNode metadata contains a cycle at $path.');
  }
  try {
    final snapshot = <String, Object?>{};
    for (final entry in value.entries) {
      final key = entry.key;
      if (key is! String) {
        throw ArgumentError(
          'GraphNode metadata map keys must be strings at $path.',
        );
      }
      snapshot[key] = _snapshotMetadataValue(entry.value, active, '$path.$key');
    }
    return Map<String, Object?>.unmodifiable(snapshot);
  } finally {
    active.remove(value);
  }
}

List<Object?> _snapshotMetadataList(
  List<Object?> value,
  Set<Object> active,
  String path,
) {
  if (!active.add(value)) {
    throw ArgumentError('GraphNode metadata contains a cycle at $path.');
  }
  try {
    return List<Object?>.unmodifiable([
      for (var index = 0; index < value.length; index++)
        _snapshotMetadataValue(value[index], active, '$path[$index]'),
    ]);
  } finally {
    active.remove(value);
  }
}

Object? _snapshotMetadataValue(Object? value, Set<Object> active, String path) {
  if (value == null || value is bool || value is String) return value;
  if (value is num) {
    if (value.isFinite) return value;
    throw ArgumentError('GraphNode metadata contains a non-finite number.');
  }
  if (value is Map) {
    return _snapshotMetadataMap(value, active, path);
  }
  if (value is List) {
    return _snapshotMetadataList(value, active, path);
  }
  throw ArgumentError(
    'GraphNode metadata contains a non-JSON value at $path: '
    '${value.runtimeType}.',
  );
}

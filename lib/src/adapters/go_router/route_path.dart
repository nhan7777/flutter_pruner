/// Composes a go_router sub-route path onto its parent path.
///
/// This mirrors go_router's `concatenatePaths`: split both sides on `/`, drop
/// empty segments, then join them under one leading slash.
String composeRoutePath(String parentPath, String childPath) {
  final segments = <String>[
    for (final segment in parentPath.split('/'))
      if (segment.isNotEmpty) segment,
    for (final segment in childPath.split('/'))
      if (segment.isNotEmpty) segment,
  ];
  return '/${segments.join('/')}';
}

/// Stable graph id for a route addressed by its full path.
String routeNodeId({required String packageName, required String fullPath}) =>
    'route:$packageName:$fullPath';

/// Stable lookup key for a route addressed by its `name:` parameter.
String routeNameKey({required String packageName, required String name}) =>
    'route:$packageName:#name=$name';

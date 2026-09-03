import 'dart:async';

import 'package:synchronized/synchronized.dart';

import '../l10n_mutation_readiness.dart';

class SharedViewEntry {
  final L10nReadinessProjectView view;
  final Lock scanLock;
  DateTime lastAccessed;

  SharedViewEntry({
    required this.view,
    required this.scanLock,
    required this.lastAccessed,
  });

  void touch() {
    lastAccessed = DateTime.now();
  }
}

class SharedViewManager {
  final Map<String, SharedViewEntry> _cache = {};
  final Map<String, Future<SharedViewEntry>> _pendingLoads = {};
  final Lock _cacheLock = Lock();
  final L10nReadinessViewProvisioner _provisionView;

  SharedViewManager({required L10nReadinessViewProvisioner provisionView})
      : _provisionView = provisionView;

  Future<SharedViewEntry> getSharedView(String projectId) async {
    return _cacheLock.synchronized(() async {
      if (_cache.containsKey(projectId)) {
        final entry = _cache[projectId]!;
        entry.touch();
        print('[SharedViewManager] Cache HIT for $projectId');
        return entry;
      }

      if (_pendingLoads.containsKey(projectId)) {
        print('[SharedViewManager] Waiting for pending load of $projectId');
        return _pendingLoads[projectId]!;
      }

      print('[SharedViewManager] Cache MISS for $projectId - loading view');
      final loadFuture = _loadView(projectId);
      _pendingLoads[projectId] = loadFuture;

      try {
        final entry = await loadFuture;
        _cache[projectId] = entry;
        print('[SharedViewManager] Cached $projectId (total cached: ${_cache.length})');
        return entry;
      } finally {
        _pendingLoads.remove(projectId);
      }
    });
  }

  Future<SharedViewEntry> _loadView(String projectId) async {
    final view = await _provisionView(projectId);
    return SharedViewEntry(
      view: view,
      scanLock: Lock(),
      lastAccessed: DateTime.now(),
    );
  }

  Future<T> withScanLock<T>(
    String projectId,
    Future<T> Function() callback,
  ) async {
    final entry = await getSharedView(projectId);
    return entry.scanLock.synchronized(callback);
  }

  Future<void> disposeAll() async {
    await _cacheLock.synchronized(() async {
      for (final entry in _cache.values) {
        await entry.view.dispose();
      }
      _cache.clear();
    });
  }

  int get cachedProjectCount => _cache.length;

  Iterable<String> get cachedProjectIds => _cache.keys;
}

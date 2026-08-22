/// Whether [path] names generated Dart output outside the editable graph.
///
/// Accepts either absolute platform paths or project-relative paths. Directory
/// checks are segment-bounded so generated-like ordinary names stay editable.
bool isGeneratedDartPath(String path) {
  final normalized = path.replaceAll(r'\', '/').toLowerCase();
  final bounded = normalized.startsWith('/') ? normalized : '/$normalized';
  return bounded.contains('/.dart_tool/') ||
      bounded.contains('/build/') ||
      normalized.endsWith('.g.dart') ||
      normalized.endsWith('.freezed.dart') ||
      normalized.endsWith('.gen.dart') ||
      normalized.endsWith('.mocks.dart') ||
      normalized.endsWith('.gr.dart');
}

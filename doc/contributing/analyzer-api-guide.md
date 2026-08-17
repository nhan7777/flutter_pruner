# Analyzer API Guide for Contributors

This guide documents the correct patterns for working with the supported
`package:analyzer` 12.1–14.x range in flutter_pruner adapters. If you're
building adapters that analyze Dart code semantically (like DartAdapter,
future FontAdapter, RouteAdapter), read this first.

---

## Quick Reference

| Task | Correct Pattern | Wrong Pattern |
|---|---|---|
| Get library source URI | `library.firstFragment.source.uri` | `library.source.uri` ❌ |
| Get imported libraries | `library.firstFragment.importedLibraries` | `library.imports` ❌ |
| Get declaration fragment | `node.declaredFragment` | `node.element.firstFragment` ❌ |
| Get element source | `element.firstFragment.source.uri` | `element.library.source.uri` ❌ |

---

## Element2/Fragment API Overview

The supported analyzer versions use the **Element2/Fragment API**. The
navigation hierarchy is:

```
Element (semantic info) → Fragment (source bridge) → LibraryFragment → Source → Uri
```

**Key types:**

- **Element**: Semantic representation (ClassElement, FunctionElement, LibraryElement)
- **Fragment**: Single declaration of an element (elements can have multiple fragments across parts)
- **LibraryFragment**: Represents a library or library part file
- **Source**: Abstract source representation
- **Uri**: File path or package URI

---

## Pattern 1: Element → File URI

Extract the file URI from any element:

```dart
Uri? getFileUri(Element element) {
  final fragment = element.firstFragment;              // Element → Fragment
  final libFragment = fragment.libraryFragment;        // Fragment → LibraryFragment
  final source = libFragment?.source;                  // LibraryFragment → Source
  final uri = source?.uri;                             // Source → Uri
  
  // Only file:// URIs can be converted to paths
  return uri != null && uri.isScheme('file')
      ? Uri.file(uri.toFilePath())
      : null;
}
```

**Why check `isScheme('file')`?**

Not all URIs are file paths:
- `package:flutter/material.dart` → package URI
- `dart:core` → Dart SDK URI
- Only `file:///...` can be converted to filesystem paths

**Example usage in DartAdapter:**

```dart
// lib/src/adapters/dart/dart_adapter.dart:77-80
final libraryUri = libraryElement.firstFragment.source.uri;
final origin = libraryUri.isScheme('file')
    ? Uri.file(libraryUri.toFilePath())
    : null;

graph.addNode(GraphNode(
  id: libraryId,
  kind: NodeKind.dartLibrary,
  displayName: libraryElement.name,
  origin: origin,  // null for non-file URIs
));
```

---

## Pattern 2: Library Imports (Element Model)

Get libraries imported by a library:

```dart
void processImports(LibraryElement library, GraphBuilder graph) {
  final libraryFragment = library.firstFragment;
  final importedLibraries = libraryFragment.importedLibraries;  // List<LibraryElement>
  
  if (importedLibraries.isNotEmpty) {
    final sourceUri = libraryFragment.source.uri;
    final location = sourceUri.isScheme('file')
        ? sourceUri.toFilePath()
        : null;
    
    for (final importedLibrary in importedLibraries) {
      final targetId = DartIds.library(project, importedLibrary);
      graph.addEdge(GraphEdge(
        from: libraryId,
        to: targetId,
        kind: EdgeKind.imports,
        evidence: Evidence(
          kind: EvidenceKind.semanticReference,
          producer: 'dart',
          description: 'import directive',
          exact: true,
          location: location,
        ),
      ));
    }
  }
}
```

**Key points:**

- Use `libraryFragment.importedLibraries` (Element model), NOT AST `ImportDirective`
- Returns `List<LibraryElement>`, not import syntax
- Resolves `show`/`hide` clauses automatically
- Works across `part` files

**Example from DartAdapter:**

```dart
// lib/src/adapters/dart/dart_adapter.dart:107-132
final libraryFragment = libraryElement.firstFragment;
final importedLibraries = libraryFragment.importedLibraries;

if (importedLibraries.isNotEmpty) {
  for (final importedLibrary in importedLibraries) {
    final targetId = DartIds.library(project, importedLibrary);
    graph.addEdge(/* ... */);
  }
}
```

---

## Pattern 3: AST Declaration Discovery

Find declarations in source files:

```dart
class DeclarationVisitor extends RecursiveAstVisitor<void> {
  @override
  void visitClassDeclaration(ClassDeclaration node) {
    super.visitClassDeclaration(node);
    
    final fragment = node.declaredFragment;  // AST → Fragment bridge
    if (fragment == null) return;
    
    _addDeclaration(fragment, NodeKind.declaration);
  }
  
  void _addDeclaration(Fragment fragment, NodeKind kind) {
    final id = DartIds.declaration(project, fragment);
    final name = fragment.name ?? '<unnamed>';
    
    // Get origin using Pattern 1
    final libFragment = fragment.libraryFragment;
    final source = libFragment?.source;
    final uri = source?.uri;
    
    final origin = uri != null && uri.isScheme('file')
        ? Uri.file(uri.toFilePath())
        : null;
    
    graph.addNode(GraphNode(
      id: id,
      kind: kind,
      displayName: name,
      origin: origin,
    ));
  }
}
```

**Key points:**

- AST nodes (`ClassDeclaration`, `FunctionDeclaration`) have `declaredFragment` getter
- Returns `Fragment?` (null for synthetic/generated nodes)
- Use fragment for stable IDs and source locations
- Don't use `node.element` directly - go through fragment

**Example from DeclarationVisitor:**

```dart
// lib/src/adapters/dart/declaration_visitor.dart:38-44
@override
void visitClassDeclaration(ClassDeclaration node) {
  super.visitClassDeclaration(node);
  
  final fragment = node.declaredFragment;
  if (fragment == null) return;
  
  _addDeclaration(fragment, NodeKind.declaration);
}
```

---

## Pattern 4: Cross-File Reference Resolution

Resolve identifier references:

```dart
class ReferenceCollector extends RecursiveAstVisitor<void> {
  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    super.visitSimpleIdentifier(node);
    
    final element = node.element;  // AST → Element resolution
    if (element == null) return;   // Unresolved reference
    
    // Check if cross-file reference
    final sourceLibrary = _getLibraryElement(element);
    if (sourceLibrary == null) return;
    
    final sourceId = DartIds.library(project, sourceLibrary);
    if (sourceId == libraryId) return;  // Skip intra-file
    
    // Get target fragment
    final fragment = _getFragment(element);
    if (fragment == null) return;
    
    final targetId = DartIds.declaration(project, fragment);
    
    // Get location for evidence
    final declaredElement = node.root.declaredElement;
    final source = declaredElement?.source;
    final location = source != null && source.uri.isScheme('file')
        ? source.uri.toFilePath()
        : null;
    
    graph.addEdge(GraphEdge(
      from: currentDeclarationId,
      to: targetId,
      kind: EdgeKind.references,
      evidence: Evidence(
        kind: EvidenceKind.semanticReference,
        producer: 'dart',
        description: 'cross-file reference',
        exact: true,
        location: location,
      ),
    ));
  }
  
  LibraryElement? _getLibraryElement(Element element) {
    Element? current = element;
    while (current != null) {
      if (current is LibraryElement) return current;
      current = current.enclosingElement;
    }
    return null;
  }
  
  Fragment? _getFragment(Element element) {
    if (element is ClassElement) return element.firstFragment;
    if (element is EnumElement) return element.firstFragment;
    if (element is TopLevelFunctionElement) return element.firstFragment;
    if (element is TopLevelVariableElement) return element.firstFragment;
    return null;
  }
}
```

**Example from ReferenceCollector:**

```dart
// lib/src/adapters/dart/reference_collector.dart:46-87
@override
void visitSimpleIdentifier(SimpleIdentifier node) {
  final element = node.element;
  if (element == null) return;
  
  final sourceLibrary = _getLibraryElement(element);
  final sourceId = DartIds.library(project, sourceLibrary);
  if (sourceId == libraryId) return;  // Skip same-library
  
  final fragment = _getFragment(element);
  if (fragment == null) return;
  
  final targetId = DartIds.declaration(project, fragment);
  graph.addEdge(/* ... */);
}
```

---

## Pattern 5: Element Annotations (Metadata)

Check for annotations like `@pragma('vm:entry-point')`:

```dart
bool _isPragmaEntryPoint(ElementAnnotation annotation) {
  final element = annotation.element;
  if (element is! ConstructorElement) return false;
  if (element.enclosingElement.name != 'pragma') return false;
  
  // Check constant value
  final value = annotation.computeConstantValue();
  if (value == null) return false;
  
  final nameField = value.getField('name');
  return nameField?.toStringValue() == 'vm:entry-point';
}

void checkElement(Element element) {
  for (final annotation in element.metadata) {  // List<ElementAnnotation>
    if (_isPragmaEntryPoint(annotation)) {
      // Mark as entry point
    }
  }
}
```

**Key points:**

- `element.metadata` returns `List<ElementAnnotation>`
- Use explicit type `ElementAnnotation`, not `Metadata` typedef
- `annotation.element` gives the constructor being invoked
- `annotation.computeConstantValue()` evaluates compile-time constant

**Example from EntryPointDetector:**

```dart
// lib/src/adapters/dart/entry_point_detector.dart:45-57
void _checkElement(Element element, String libraryId) {
  for (final annotation in element.metadata) {
    if (_isPragmaEntryPoint(annotation)) {
      final fragment = _getFragment(element);
      if (fragment != null) {
        final declId = DartIds.declaration(project, fragment);
        graph.addRoot(declId, reason: "@pragma('vm:entry-point')");
      }
      return;
    }
  }
}
```

---

## AST vs Element Model

Two parallel representations of Dart code:

| Layer | Purpose | Types | When to Use |
|---|---|---|---|
| **AST** | Syntax structure | `ClassDeclaration`, `FunctionDeclaration`, `ImportDirective` | Finding declarations, locations |
| **Element** | Semantic info | `ClassElement`, `FunctionElement`, `LibraryElement` | Resolving references, types |
| **Fragment** | Bridge | `Fragment`, `LibraryFragment` | Connecting Element → Source |

**Navigation:**

```dart
// AST → Fragment → Element
ClassDeclaration astNode;
Fragment fragment = astNode.declaredFragment;  // AST → Fragment
ClassElement element = fragment.element;       // Fragment → Element

// AST → Element (direct, but limited)
SimpleIdentifier identifier;
Element? element = identifier.element;         // May be null

// Element → Fragment → Source
ClassElement element;
Fragment fragment = element.firstFragment;     // Element → Fragment
Source source = fragment.libraryFragment.source; // Fragment → Source
```

**Rules of thumb:**

- Use **AST visitors** to discover declarations (`visitClassDeclaration`)
- Use **Element model** for semantic queries (imports, references, types)
- Use **Fragment** to bridge from Element to source location
- Don't mix layers - pick one and stay there until bridge points

---

## Common Mistakes

### ❌ Mistake 1: Wrong library source access

```dart
// WRONG - this API doesn't exist
element.library.source.uri

// CORRECT
element.firstFragment.source.uri
```

### ❌ Mistake 2: Using AST imports for semantic edges

```dart
// WRONG - ImportDirective is syntax, not semantic
unit.directives.whereType<ImportDirective>()

// CORRECT - importedLibraries is resolved Element model
libraryElement.firstFragment.importedLibraries
```

### ❌ Mistake 3: Forgetting null safety

```dart
// WRONG - Uri? can't be assigned to Uri
final origin = fragment.libraryFragment.source.uri;

// CORRECT - check null and scheme
final source = fragment.libraryFragment?.source;
final uri = source?.uri;
final origin = uri != null && uri.isScheme('file')
    ? Uri.file(uri.toFilePath())
    : null;
```

### ❌ Mistake 4: Calling toFilePath() on non-file URIs

```dart
// WRONG - crashes on package: or dart: URIs
final path = source.uri.toFilePath();

// CORRECT - check scheme first
if (source.uri.isScheme('file')) {
  final path = source.uri.toFilePath();
}
```

### ❌ Mistake 5: Using Metadata typedef instead of ElementAnnotation

```dart
// CONFUSING - Metadata is deprecated typedef
for (final annotation in element.metadata) {
  Metadata m = annotation;  // Type confusion
}

// CLEAR - use explicit type
for (final annotation in element.metadata) {
  ElementAnnotation a = annotation;  // Clear intent
}
```

---

## Verification Checklist

Before submitting analyzer-related code:

- [ ] No `element.library.source.uri` (use `element.firstFragment.source.uri`)
- [ ] No AST `ImportDirective` for semantic imports (use `libraryFragment.importedLibraries`)
- [ ] All Uri extractions check `isScheme('file')` before `toFilePath()`
- [ ] Null safety: `source?.uri` and `uri != null` checks present
- [ ] Explicit `ElementAnnotation` type, not `Metadata` typedef
- [ ] AST visitors use `declaredFragment`, not direct element access
- [ ] Tests cover actual Dart files, not just mock elements

---

## Testing Patterns

### Test Real Dart Files

Don't mock elements - use real analyzer:

```dart
test('detects unreachable function', () async {
  final tempDir = Directory.systemTemp.createTempSync();
  
  // Write real Dart files
  File('${tempDir.path}/main.dart').writeAsStringSync('''
    void main() {
      used();
    }
    void used() {}
    void unused() {}  // Should be detected
  ''');
  
  File('${tempDir.path}/pubspec.yaml').writeAsStringSync('''
    name: test_project
    environment:
      sdk: ^3.9.0
  ''');
  
  // Run real analyzer
  final project = ProjectContext(root: tempDir, packageName: 'test_project');
  final graph = ReachabilityGraph();
  final builder = GraphBuilder(graph, 'dart');
  
  await DartAdapter().analyze(project, builder);
  
  // Check results
  expect(
    graph.nodes.any((n) => n.displayName == 'unused'),
    isTrue,
  );
});
```

### Verify Against Analyzer Output

```bash
# Run analyzer on test fixtures
dart analyze test/fixtures/dart_declarations/

# Should not report errors on valid test code
```

---

## References

- **Analyzer package:** `~/.pub-cache/hosted/pub.dev/analyzer-<version>/`
- **Element API:** `lib/dart/element/element.dart`
- **AST API:** `lib/dart/ast/ast.dart`
- **DartAdapter implementation:** `lib/src/adapters/dart/`

---

## Getting Help

If you encounter analyzer API issues:

1. Read the installed analyzer source directly:
   ```bash
   less ~/.pub-cache/hosted/pub.dev/analyzer-*/lib/dart/element/element.dart
   ```

2. Check analyzer CHANGELOG for breaking changes:
   ```bash
   less ~/.pub-cache/hosted/pub.dev/analyzer-*/CHANGELOG.md
   ```

3. Look at DartAdapter implementation as reference:
   - `lib/src/adapters/dart/dart_adapter.dart`
   - `lib/src/adapters/dart/declaration_visitor.dart`
   - `lib/src/adapters/dart/reference_collector.dart`

4. Ask in GitHub issues with:
   - Analyzer version from `pubspec.yaml`
   - Code snippet showing API usage
   - Full error message from `dart analyze`

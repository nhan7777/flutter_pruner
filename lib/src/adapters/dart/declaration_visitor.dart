import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';

import '../../core/graph/node.dart';
import '../../core/project/project_context.dart';
import '../analyzer_adapter.dart';
import 'dart_ids.dart';

/// Visits AST declarations and creates graph nodes.
class DeclarationVisitor extends RecursiveAstVisitor<void> {
  /// Creates a visitor writing declaration nodes into [graph].
  DeclarationVisitor({
    required this.project,
    required this.graph,
    required this.libraryId,
  });

  /// Project the analysis runs against.
  final ProjectContext project;

  /// Graph surface to write nodes into.
  final GraphBuilder graph;

  /// Id of the library owning the visited unit.
  final String libraryId;

  final List<String> _declarationIds = [];

  /// Returns all declaration IDs found in this unit.
  List<String> get declarationIds => List.unmodifiable(_declarationIds);

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    super.visitFunctionDeclaration(node);

    // A FunctionDeclaration can also represent a named local function. The
    // graph currently models top-level declarations only.
    if (node.parent is! CompilationUnit) return;

    final fragment = node.declaredFragment;
    if (fragment == null) return;

    _addDeclaration(fragment, NodeKind.declaration);
  }

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    super.visitClassDeclaration(node);

    final fragment = node.declaredFragment;
    if (fragment == null) return;

    _addDeclaration(fragment, NodeKind.declaration);
  }

  @override
  void visitEnumDeclaration(EnumDeclaration node) {
    super.visitEnumDeclaration(node);

    final fragment = node.declaredFragment;
    if (fragment == null) return;

    _addDeclaration(fragment, NodeKind.declaration);
  }

  @override
  void visitMixinDeclaration(MixinDeclaration node) {
    super.visitMixinDeclaration(node);

    final fragment = node.declaredFragment;
    if (fragment == null) return;

    _addDeclaration(fragment, NodeKind.declaration);
  }

  @override
  void visitExtensionDeclaration(ExtensionDeclaration node) {
    super.visitExtensionDeclaration(node);

    final fragment = node.declaredFragment;
    if (fragment == null) return;

    _addDeclaration(
      fragment,
      NodeKind.declaration,
      removalSupported: node.name != null,
    );
  }

  @override
  void visitExtensionTypeDeclaration(ExtensionTypeDeclaration node) {
    super.visitExtensionTypeDeclaration(node);

    final fragment = node.declaredFragment;
    if (fragment == null) return;

    _addDeclaration(fragment, NodeKind.declaration);
  }

  @override
  void visitGenericTypeAlias(GenericTypeAlias node) {
    super.visitGenericTypeAlias(node);

    final fragment = node.declaredFragment;
    if (fragment == null) return;

    _addDeclaration(fragment, NodeKind.declaration);
  }

  @override
  void visitTopLevelVariableDeclaration(TopLevelVariableDeclaration node) {
    super.visitTopLevelVariableDeclaration(node);

    for (final variable in node.variables.variables) {
      final fragment = variable.declaredFragment;
      if (fragment == null) continue;

      _addDeclaration(
        fragment,
        NodeKind.declaration,
        removalSupported: node.variables.variables.length == 1,
      );
    }
  }

  void _addDeclaration(
    Fragment fragment,
    NodeKind kind, {
    bool removalSupported = true,
  }) {
    final id = DartIds.declaration(project, fragment);
    final name = fragment.name ?? '<unnamed>';

    final libFragment = fragment.libraryFragment;
    final source = libFragment?.source;
    // Analyzer may expose project libraries through a package: URI. Apply
    // needs the physical source path, which Source.fullName preserves.
    final origin = source != null ? Uri.file(source.fullName) : Uri();
    final relativePath = source == null
        ? ''
        : project.relative(source.fullName);
    final externallyAddressable =
        relativePath.startsWith('lib/') && !name.startsWith('_');

    graph.addNode(
      GraphNode(
        id: id,
        kind: kind,
        displayName: name,
        origin: origin,
        metadata: {
          'removalSupported': removalSupported,
          'externallyAddressable': externallyAddressable,
        },
      ),
    );

    // Protect declarations that are wired by frameworks at runtime.
    // Static reference analysis cannot see these callers, so without
    // protection they would be reported as SAFE — a wrong deletion.
    final protectionReason = _frameworkProtectionReason(name);
    if (protectionReason != null) {
      graph.protect(id, reason: protectionReason);
    }

    _declarationIds.add(id);
  }

  /// Returns a protection reason when [name] matches a framework-wired
  /// naming convention, or null when no protection applies.
  ///
  /// These conventions represent classes that are instantiated or registered
  /// by an external framework at runtime, making static reference tracing
  /// insufficient to prove the class is unreachable.
  ///
  /// **Dependency Injection:**
  /// - `*Module` — GetIt/injectable modules registered via @module annotation
  /// - `*Binding` — GetX dependency binding classes
  ///
  /// **State Management:**
  /// - `*Bloc`, `*Cubit` — BLoC pattern state managers
  /// - `*Event` — BLoC pattern event classes
  /// - `*State` (non-private) — BLoC/Cubit state classes
  /// - `*Controller` — GetX/MVC controllers
  /// - `*Provider` — Riverpod providers (though typically generated)
  /// - `*Notifier` — Riverpod StateNotifier classes
  /// - `*ViewModel` — MVVM pattern view models
  /// - `*Action` — Redux action classes
  /// - `*Reducer` — Redux reducer functions
  /// - `*Middleware` — Redux middleware
  ///
  /// **Routing:**
  /// - `*Route` — AutoRoute/GoRouter declarations
  /// - `*Screen`, `*Page` — routing destinations
  ///
  /// **Clean Architecture:**
  /// - `*UseCase` — use case implementations
  /// - `*Repository`, `*RepositoryImpl` — repository pattern
  /// - `*DataSource`, `*Datasource` — data layer boundaries
  ///
  /// **Generated Code Partners:**
  /// Classes that pair with code generation where the class itself has no
  /// static references but the generated code depends on it:
  /// - Models with @JsonSerializable, @freezed, etc. are handled via
  ///   annotation detection, not naming patterns.
  ///
  /// See: https://bloclibrary.dev/naming-conventions/
  /// See: https://docs.flutter.dev/data-and-backend/state-mgmt/simple
  String? _frameworkProtectionReason(String name) {
    final lowerName = name.toLowerCase();

    // Dependency Injection
    if (name.endsWith('Module')) {
      return 'DI module — registered via @module annotation at runtime';
    }
    if (name.endsWith('Binding')) {
      return 'GetX binding — wired by GetX routing framework';
    }

    // State Management - BLoC
    if (lowerName.endsWith('bloc')) {
      return 'BLoC state manager — registered via BlocProvider at runtime';
    }
    if (lowerName.endsWith('cubit')) {
      return 'Cubit state manager — registered via BlocProvider at runtime';
    }
    if (name.endsWith('Event') && !name.startsWith('_')) {
      return 'BLoC event class — dispatched via context.read<Bloc>().add()';
    }
    // Only protect non-private State classes (BLoC states, not StatefulWidget _*State)
    if (name.endsWith('State') && !name.startsWith('_')) {
      return 'BLoC/Cubit state class — emitted by state manager';
    }

    // State Management - GetX
    if (name.endsWith('Controller')) {
      return 'GetX/MVC controller — registered via Get.put() or binding';
    }

    // State Management - Riverpod
    if (name.endsWith('Provider') && !name.startsWith('_')) {
      return 'Riverpod provider — accessed via ref.watch() at runtime';
    }
    if (name.endsWith('Notifier')) {
      return 'Riverpod notifier — StateNotifier registered via provider';
    }

    // State Management - MVVM
    if (name.endsWith('ViewModel')) {
      return 'MVVM view model — business logic layer';
    }

    // State Management - Redux
    if (name.endsWith('Action')) {
      return 'Redux action — dispatched to store';
    }
    if (name.endsWith('Reducer')) {
      return 'Redux reducer — pure state transformation function';
    }
    if (name.endsWith('Middleware')) {
      return 'Redux middleware — intercepts actions before reducers';
    }

    // Routing
    if (name.endsWith('Route')) {
      return 'Router declaration — referenced by routing framework at runtime';
    }
    if (name.endsWith('Screen') || name.endsWith('Page')) {
      return 'Routing destination — navigated to via router framework';
    }

    // Clean Architecture
    if (name.endsWith('UseCase')) {
      return 'Use case — invoked via DI container or provider';
    }
    if (name.endsWith('Repository') || name.endsWith('RepositoryImpl')) {
      return 'Repository pattern — injected via DI as interface implementation';
    }
    if (lowerName.endsWith('datasource')) {
      return 'Data source — injected via DI as data layer boundary';
    }

    return null;
  }
}

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/error/error.dart';

import '../../core/graph/build_condition.dart';
import '../../core/graph/edge.dart';
import '../../core/graph/evidence.dart';
import '../../core/graph/node.dart';
import '../../core/project/project_context.dart';
import '../../core/project/target_matrix.dart';
import '../adapter_report_definition.dart';
import '../analyzer_adapter.dart';
import 'analyzer_ast_compat.dart';
import 'analyzer_diagnostic_collector.dart';
import 'dart_adapter_profile.dart';
import 'dart_analysis_workspace.dart';
import 'dart_ids.dart';
import 'declaration_visitor.dart';
import 'entry_point_detector.dart';
import 'reference_collector.dart';
import 'unresolved_reference_index.dart';

/// Collects lint-inclusive analyzer diagnostics for one project.
typedef AnalyzerDiagnosticCollectorCallback =
    Future<AnalyzerDiagnosticCollection> Function(ProjectContext project);

/// Analyzes Dart source code for unused declarations and libraries.
///
/// Builds a semantic graph of Dart libraries, top-level and member declarations,
/// and cross-file references resolved through the analyzer's element model.
class DartAdapter extends AnalyzerAdapter {
  /// Creates a Dart declaration analyzer.
  const DartAdapter({
    AnalyzerDiagnosticCollectorCallback collectAnalyzerDiagnostics =
        _collectDiagnosticsWithCli,
  }) : _collectAnalyzerDiagnostics = collectAnalyzerDiagnostics;

  final AnalyzerDiagnosticCollectorCallback _collectAnalyzerDiagnostics;

  static Future<AnalyzerDiagnosticCollection> _collectDiagnosticsWithCli(
    ProjectContext project,
  ) => AnalyzerDiagnosticCollector().collect(project);

  @override
  String get id => 'dart';

  @override
  String get name => 'Dart declaration analyzer';

  @override
  Set<String> get findingNodeSchemes => const {'dart', 'dart-diagnostic'};

  @override
  AdapterReportDefinition get reportDefinition => AdapterReportDefinition(
    adapterId: 'dart',
    displayName: 'Dart declaration analyzer',
    description:
        'Builds a semantic Dart graph and reports unreachable declarations and libraries.',
    findings: [
      AdapterFindingReportDefinition(
        nodeKind: NodeKind.declaration,
        ruleId: 'PRN-DART-001',
        title: 'Unreachable declaration',
        nodeLabel: 'Dart declaration',
        description:
            'A Dart declaration with no path from the configured roots.',
        measurementKind: 'source-bytes',
      ),
      AdapterFindingReportDefinition(
        nodeKind: NodeKind.dartLibrary,
        ruleId: 'PRN-DART-002',
        title: 'Unreachable library',
        nodeLabel: 'Dart library',
        description: 'A Dart library with no path from the configured roots.',
        measurementKind: 'source-bytes',
      ),
      AdapterFindingReportDefinition(
        nodeKind: NodeKind.analyzerDiagnostic,
        ruleId: 'PRN-DART-003',
        title: 'Analyzer unused diagnostic',
        nodeLabel: 'Analyzer diagnostic',
        description:
            'An unused construct reported by the Dart analyzer that requires '
            'a dedicated editor before it can be applied safely.',
        details: [
          AdapterReportDetailDefinition(
            key: 'diagnosticCode',
            label: 'Diagnostic code',
            valueType: AdapterReportDetailValueType.text,
          ),
          AdapterReportDetailDefinition(
            key: 'message',
            label: 'Message',
            valueType: AdapterReportDetailValueType.text,
          ),
          AdapterReportDetailDefinition(
            key: 'line',
            label: 'Line',
            valueType: AdapterReportDetailValueType.integer,
          ),
          AdapterReportDetailDefinition(
            key: 'column',
            label: 'Column',
            valueType: AdapterReportDetailValueType.integer,
          ),
        ],
      ),
    ],
    measurements: [
      AdapterReportMeasurementDefinition(
        kind: 'source-bytes',
        label: 'Source size',
        unit: 'bytes',
        description: 'Source bytes associated with an individual finding.',
      ),
      AdapterReportMeasurementDefinition(
        kind: 'dart-finding-source-bytes',
        label: 'Dart source size',
        unit: 'bytes',
        description: 'Known source bytes for reported Dart findings.',
      ),
    ],
  );

  @override
  bool appliesTo(ProjectContext project) => true;

  @override
  Future<void> analyze(ProjectContext project, GraphBuilder graph) async {
    await _analyze(project, graph, DartAnalysisWorkspace(project));
  }

  @override
  Future<void> analyzeWithServices(
    ProjectContext project,
    GraphBuilder graph,
    AdapterServices services,
  ) async {
    await _analyze(
      project,
      graph,
      services.dartWorkspace ?? DartAnalysisWorkspace(project),
      profile: services.dartProfile,
    );
  }

  Future<void> _analyze(
    ProjectContext project,
    GraphBuilder graph,
    DartAnalysisWorkspace workspace, {
    DartAdapterProfile? profile,
  }) async {
    _registerConfiguredRoots(project, graph);
    final cliDiagnosticsFuture = profile == null
        ? _collectAnalyzerDiagnostics(project)
        : profile.measureAsync(
            'cliDiagnostics',
            () => _collectAnalyzerDiagnostics(project),
          );

    final entryPointDetector = EntryPointDetector(
      project: project,
      graph: graph,
    );
    final modeledPaths = <String>{};
    final conditionalDirectivePaths = <String>{};
    final unresolvedReferenceIndex = UnresolvedReferenceIndex(project);
    final unresolvedReferences = <UnresolvedReferenceFact>{};
    final generatedUnresolvedReferences = <UnresolvedReferenceFact>{};

    final dartFiles =
        profile?.measure('fileEnumeration', () => workspace.dartFiles) ??
        workspace.dartFiles;
    for (final filePath in dartFiles) {
      final isModeled = DartIds.isModeledProjectPath(project, filePath);
      final isGenerated = DartIds.isGeneratedProjectPath(project, filePath);
      if (!isModeled && !isGenerated) {
        continue;
      }

      final library = profile == null
          ? await workspace.resolveLibrary(filePath)
          : await profile.measureAsync(
              'resolveLibrary',
              () => workspace.resolveLibrary(filePath),
            );

      if (library is ResolvedLibraryResult) {
        _collectConditionalDirectivePaths(
          project,
          library,
          conditionalDirectivePaths,
        );
      }

      if (!isModeled) {
        _recordGeneratedLibrary(
          project,
          graph,
          library,
          filePath,
          generatedUnresolvedReferences,
        );
        continue;
      }

      if (library is NotLibraryButPartResult) continue;
      if (library is! ResolvedLibraryResult) {
        graph.addBlocker(
          reason: 'analyzer could not resolve a Dart library',
          location: filePath,
        );
        continue;
      }

      modeledPaths.addAll(library.units.map((unit) => unit.path));

      Future<void> analyzeLibrary() => _analyzeLibrary(
        project,
        graph,
        library,
        entryPointDetector,
        unresolvedReferenceIndex,
        unresolvedReferences,
        generatedUnresolvedReferences,
        profile: profile,
      );
      if (profile == null) {
        await analyzeLibrary();
      } else {
        await profile.measureAsync('analyzeLibrary', analyzeLibrary);
      }
    }

    _addUnresolvedReferenceBlockers(
      project,
      graph,
      unresolvedReferenceIndex,
      unresolvedReferences,
      sourceScoped: true,
    );
    _addUnresolvedReferenceBlockers(
      project,
      graph,
      unresolvedReferenceIndex,
      generatedUnresolvedReferences,
      sourceScoped: false,
    );

    // Dart's analyzer resolves one active conditional branch for the host
    // process. Until the graph models every target-specific branch, none of
    // the package's Dart declarations may be considered removable. Keep the
    // blocker source-less so an unreachable library containing the directive
    // cannot deactivate the protection.
    for (final path in conditionalDirectivePaths.toList()..sort()) {
      graph.addBlocker(
        reason: 'conditional Dart imports/exports are not modelled per target',
        location: path,
        affectedNamespace: 'dart:${project.packageName}/',
      );
    }

    _addEmptyFiles(project, graph, modeledPaths);

    final cliDiagnostics = profile == null
        ? await cliDiagnosticsFuture
        : await profile.measureAsync(
            'cliDiagnosticsWait',
            () => cliDiagnosticsFuture,
          );
    if (!cliDiagnostics.available) {
      graph.addBlocker(
        reason:
            'lint-inclusive analyzer diagnostics were unavailable: '
            '${cliDiagnostics.failure}',
        location: project.root.path,
      );
    } else {
      for (final diagnostic in cliDiagnostics.diagnostics) {
        _addUnusedDiagnosticNode(
          project,
          graph,
          path: diagnostic.path,
          code: diagnostic.code,
          message: diagnostic.message,
          line: diagnostic.line,
          column: diagnostic.column,
          length: diagnostic.length,
          offset: diagnostic.offset,
        );
      }
    }
  }

  void _registerConfiguredRoots(ProjectContext project, GraphBuilder graph) {
    if (project.rootCoverage.mode == RootCoverageMode.applicationEntrypoints) {
      for (final entrypoint
          in project.targets.map((target) => target.entrypoint).toSet()) {
        final libraryId = DartIds.libraryPath(
          project,
          project.resolve(entrypoint),
        );
        final condition = BuildCondition(entrypoints: {entrypoint});
        graph.addRoot(
          libraryId,
          reason: 'contains main() entry point',
          condition: condition,
        );
        graph.addRoot(
          '$libraryId#main',
          reason: 'main() entry point',
          condition: condition,
        );
      }
    }

    for (final entrypoint in project.rootCoverage.publicEntrypoints) {
      graph.addRoot(
        DartIds.libraryPath(project, project.resolve(entrypoint)),
        reason: 'public package entry library — imported by external consumers',
      );
    }
  }

  void _collectConditionalDirectivePaths(
    ProjectContext project,
    ResolvedLibraryResult library,
    Set<String> paths,
  ) {
    for (final unit in library.units) {
      final isProjectUnit =
          DartIds.isModeledProjectPath(project, unit.path) ||
          DartIds.isGeneratedProjectPath(project, unit.path);
      if (!isProjectUnit) continue;
      final hasConditionalDirective = unit.unit.directives.any(
        (directive) =>
            (directive is ImportDirective &&
                directive.configurations.isNotEmpty) ||
            (directive is ExportDirective &&
                directive.configurations.isNotEmpty),
      );
      if (hasConditionalDirective) paths.add(unit.path);
    }
  }

  void _recordGeneratedLibrary(
    ProjectContext project,
    GraphBuilder graph,
    Object library,
    String filePath,
    Set<UnresolvedReferenceFact> unresolvedReferences,
  ) {
    if (library is NotLibraryButPartResult) return;
    if (library is! ResolvedLibraryResult) {
      graph.addBlocker(
        reason: 'analyzer could not resolve a generated Dart library',
        location: filePath,
      );
      return;
    }

    final affectedNodeIds = <String>{};
    var hasErrors = false;
    for (final unit in library.units) {
      final collector = GeneratedReferenceCollector(project: project)
        ..visitLibrary(unit.unit);
      affectedNodeIds.addAll(collector.affectedNodeIds);
      final unresolvedCollector = ReferenceCollector(
        project: project,
        graph: graph,
        libraryId: DartIds.libraryPath(project, unit.path),
        location: unit.path,
        recordReferences: false,
      )..visitLibrary(unit.unit);
      unresolvedReferences.addAll(unresolvedCollector.unresolvedReferences);
      hasErrors =
          hasErrors ||
          unit.diagnostics.any(
            (diagnostic) =>
                diagnostic.diagnosticCode.severity == DiagnosticSeverity.ERROR,
          );
    }

    if (affectedNodeIds.isNotEmpty) {
      graph.addBlocker(
        reason:
            'generated code references source declarations that cannot be '
            'edited independently',
        location: filePath,
        affectedNodeIds: affectedNodeIds,
      );
    }
    if (hasErrors) {
      graph.addBlocker(
        reason: 'analyzer could not fully resolve a generated Dart library',
        location: filePath,
      );
    }
  }

  void _addEmptyFiles(
    ProjectContext project,
    GraphBuilder graph,
    Set<String> modeledPaths,
  ) {
    for (final file in project.dartFiles) {
      if (!DartIds.isModeledProjectPath(project, file.path) ||
          modeledPaths.contains(file.path)) {
        continue;
      }
      final parsed = parseString(
        content: file.readAsStringSync(),
        path: file.path,
        throwIfDiagnostics: false,
      );
      final hasErrors = parsed.errors.any(
        (diagnostic) =>
            diagnostic.diagnosticCode.severity == DiagnosticSeverity.ERROR,
      );
      if (hasErrors ||
          parsed.unit.directives.isNotEmpty ||
          parsed.unit.declarations.isNotEmpty) {
        continue;
      }
      graph.addNode(
        GraphNode(
          id: DartIds.libraryPath(project, file.path),
          kind: NodeKind.dartLibrary,
          displayName: '<empty library>',
          origin: Uri.file(file.path),
          metadata: const {
            'declarationCount': 0,
            'directiveCount': 0,
            'generatedPartPaths': <String>[],
          },
        ),
      );
    }
  }

  Future<void> _analyzeLibrary(
    ProjectContext project,
    GraphBuilder graph,
    ResolvedLibraryResult library,
    EntryPointDetector entryPointDetector,
    UnresolvedReferenceIndex unresolvedReferenceIndex,
    Set<UnresolvedReferenceFact> unresolvedReferences,
    Set<UnresolvedReferenceFact> generatedUnresolvedReferences, {
    DartAdapterProfile? profile,
  }) async {
    final libraryElement = library.element;
    final libraryId = DartIds.library(project, libraryElement);

    final editableUnits = library.units
        .where((unit) => DartIds.isModeledProjectPath(project, unit.path))
        .toList(growable: false);
    final generatedPartPaths = library.units
        .where((unit) => DartIds.isGeneratedPath(unit.path))
        .map((unit) => unit.path)
        .toList(growable: false);
    final declarationCount = editableUnits.fold<int>(
      0,
      (count, unit) => count + unit.unit.declarations.length,
    );
    final directiveCount = editableUnits.fold<int>(
      0,
      (count, unit) => count + unit.unit.directives.length,
    );

    // Create library node
    final librarySource = libraryElement.firstFragment.source;
    final origin = Uri.file(librarySource.fullName);
    final libraryPath = libraryElement.firstFragment.source.fullName;
    final relativeLibraryPath = project.relative(libraryPath);

    graph.addNode(
      GraphNode(
        id: libraryId,
        kind: NodeKind.dartLibrary,
        displayName: libraryElement.name?.isNotEmpty ?? false
            ? libraryElement.name!
            : '<unnamed library>',
        origin: origin,
        metadata: {
          'declarationCount': declarationCount,
          'directiveCount': directiveCount,
          'generatedPartPaths': generatedPartPaths,
          'externallyAddressable': relativeLibraryPath.startsWith('lib/'),
        },
      ),
    );

    if (relativeLibraryPath.startsWith('test/')) {
      graph.addRoot(
        libraryId,
        reason: 'test library — invoked dynamically by the test runner',
      );
    }
    final publicEntrypoints = project.rootCoverage.publicEntrypoints;
    final conventionalPublicEntrypoint = 'lib/${project.packageName}.dart';
    if (publicEntrypoints.contains(relativeLibraryPath) ||
        (project.rootCoverage.mode == RootCoverageMode.inferred &&
            relativeLibraryPath == conventionalPublicEntrypoint)) {
      graph.addRoot(
        libraryId,
        reason: 'public package entry library — imported by external consumers',
      );
      for (final element
          in libraryElement.exportNamespace.definedNames2.values) {
        final fragment = DartIds.declarationFragment(element);
        if (fragment == null ||
            !DartIds.isModeledProjectFragment(project, fragment)) {
          continue;
        }
        graph.addEdge(
          GraphEdge(
            from: libraryId,
            to: DartIds.declaration(project, fragment),
            kind: EdgeKind.references,
            evidence: Evidence(
              kind: EvidenceKind.configuration,
              producer: 'dart',
              description: 'public package API',
              exact: true,
              location: libraryPath,
            ),
          ),
        );
      }
    }

    // Detect entry points (main, @pragma)
    entryPointDetector.detectInLibrary(libraryElement);

    // Visit each unit to collect declarations.
    // A library may include part files (e.g., .g.dart) that should be
    // excluded.  Apply the same exclusion list per-unit, not only at the
    // top-level library path.
    for (final unit in library.units) {
      if (!DartIds.isModeledProjectPath(project, unit.path)) {
        if (DartIds.isGeneratedPath(unit.path)) {
          final generatedReferences = GeneratedReferenceCollector(
            project: project,
          )..visitLibrary(unit.unit);
          if (generatedReferences.affectedNodeIds.isNotEmpty) {
            graph.addBlocker(
              reason:
                  'generated code references source declarations that '
                  'cannot be edited independently',
              location: unit.path,
              affectedNodeIds: generatedReferences.affectedNodeIds,
            );
          }
          final unresolvedCollector = ReferenceCollector(
            project: project,
            graph: graph,
            libraryId: libraryId,
            location: unit.path,
            recordReferences: false,
          )..visitLibrary(unit.unit);
          generatedUnresolvedReferences.addAll(
            unresolvedCollector.unresolvedReferences,
          );
          if (unit.diagnostics.any(
            (diagnostic) =>
                diagnostic.diagnosticCode.severity == DiagnosticSeverity.ERROR,
          )) {
            graph.addBlocker(
              reason:
                  'analyzer could not fully resolve a generated Dart library',
              location: unit.path,
            );
          }
        }
        continue;
      }

      final visitor = DeclarationVisitor(
        project: project,
        graph: graph,
        libraryId: libraryId,
      );

      if (profile == null) {
        unit.unit.visitChildren(visitor);
      } else {
        profile.measure('declarationVisitor', () {
          unit.unit.visitChildren(visitor);
        });
      }

      if (profile == null) {
        await _addUnusedDiagnostics(project, graph, unit);
      } else {
        await profile.measureAsync(
          'sessionDiagnostics',
          () => _addUnusedDiagnostics(project, graph, unit),
        );
      }

      // Create import edges from LibraryFragment
      final libraryFragment = libraryElement.firstFragment;
      final importedLibraries = libraryFragment.importedLibraries;

      if (importedLibraries.isNotEmpty) {
        final sourceUri = libraryFragment.source.uri;
        final location = sourceUri.isScheme('file')
            ? sourceUri.toFilePath()
            : null;

        for (final importedLibrary in importedLibraries) {
          if (!DartIds.isModeledProjectLibrary(project, importedLibrary)) {
            continue;
          }
          final targetId = DartIds.library(project, importedLibrary);
          graph.addEdge(
            GraphEdge(
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
            ),
          );
        }
      }

      for (final exportedLibrary in libraryElement.exportedLibraries) {
        if (!DartIds.isModeledProjectLibrary(project, exportedLibrary)) {
          continue;
        }
        graph.addEdge(
          GraphEdge(
            from: libraryId,
            to: DartIds.library(project, exportedLibrary),
            kind: EdgeKind.imports,
            evidence: Evidence(
              kind: EvidenceKind.configuration,
              producer: 'dart',
              description: 'export directive',
              exact: true,
              location: libraryPath,
            ),
          ),
        );
      }

      // Collect references once. The collector attributes each reference to
      // its nearest enclosing top-level declaration.
      final collector = ReferenceCollector(
        project: project,
        graph: graph,
        libraryId: libraryId,
        location: unit.path,
      );
      if (profile == null) {
        unresolvedReferenceIndex.indexUnit(unit.unit, unit.path);
        collector.visitLibrary(unit.unit);
      } else {
        profile.measure(
          'unresolvedReferenceIndex',
          () => unresolvedReferenceIndex.indexUnit(unit.unit, unit.path),
        );
        profile.measure('referenceVisitor', () {
          collector.visitLibrary(unit.unit);
        });
      }
      unresolvedReferences.addAll(collector.unresolvedReferences);

      final analysisErrors = unit.diagnostics
          .where(
            (diagnostic) =>
                diagnostic.diagnosticCode.severity == DiagnosticSeverity.ERROR,
          )
          .toList(growable: false);
      if (_requiresNamespaceDiagnosticFallback(
        analysisErrors,
        collector.unresolvedReferences,
        unit.unit,
      )) {
        graph.addBlocker(
          reason: 'analyzer could not fully resolve this Dart unit',
          location: unit.path,
          affectedNamespace: 'dart:${project.packageName}/',
        );
      }
    }
  }

  void _addUnresolvedReferenceBlockers(
    ProjectContext project,
    GraphBuilder graph,
    UnresolvedReferenceIndex index,
    Set<UnresolvedReferenceFact> facts, {
    required bool sourceScoped,
  }) {
    final ordered = facts.toList()
      ..sort((left, right) {
        final location = left.location.compareTo(right.location);
        if (location != 0) return location;
        final offset = left.offset.compareTo(right.offset);
        if (offset != 0) return offset;
        return (left.name ?? '').compareTo(right.name ?? '');
      });
    for (final fact in ordered) {
      final candidates = index.candidatesFor(fact);
      if (fact.name == null || fact.name!.isEmpty) {
        graph.addBlocker(
          reason: 'analyzer returned an unresolved semantic reference',
          location: fact.location,
          sourceNodeId: sourceScoped ? fact.callerId : null,
          affectedNamespace: 'dart:${project.packageName}/',
        );
      } else if (candidates.isNotEmpty) {
        graph.addBlocker(
          reason: 'analyzer returned an unresolved semantic reference',
          location: fact.location,
          sourceNodeId: sourceScoped ? fact.callerId : null,
          affectedNodeIds: candidates,
        );
      }
    }
  }

  bool _requiresNamespaceDiagnosticFallback(
    // ignore: deprecated_member_use
    List<AnalysisError> diagnostics,
    Set<UnresolvedReferenceFact> facts,
    CompilationUnit unit,
  ) {
    const capturedSemanticCodes = {
      'extends_non_class',
      'undefined_class',
      'undefined_function',
      'undefined_getter',
      'undefined_identifier',
      'undefined_method',
      'undefined_operator',
      'undefined_setter',
      'undefined_type',
    };
    for (final diagnostic in diagnostics) {
      final code = AnalyzerDiagnosticCollector.normalizeCode(
        diagnostic.diagnosticCode.lowerCaseUniqueName,
      );
      if (code == 'undefined_named_parameter' &&
          _hasResolvedNamedParameterTarget(unit, diagnostic)) {
        continue;
      }
      final diagnosticEnd = diagnostic.offset + diagnostic.length;
      final hasMatchingFact = facts.any(
        (fact) =>
            fact.offset < diagnosticEnd &&
            diagnostic.offset < fact.offset + fact.length,
      );
      if (capturedSemanticCodes.contains(code) && hasMatchingFact) continue;
      return true;
    }
    return false;
  }

  bool _hasResolvedNamedParameterTarget(
    CompilationUnit unit,
    // ignore: deprecated_member_use
    AnalysisError diagnostic,
  ) {
    final finder = _NamedArgumentAtOffsetFinder(diagnostic.offset);
    unit.accept(finder);
    AstNode? current = finder.match;
    while (current != null) {
      if (current is MethodInvocation) {
        return current.methodName.element is ExecutableElement;
      }
      if (current is InstanceCreationExpression) {
        return current.constructorName.element is ExecutableElement;
      }
      if (current is FunctionExpressionInvocation) {
        return current.element is ExecutableElement;
      }
      current = current.parent;
    }
    return false;
  }

  Future<void> _addUnusedDiagnostics(
    ProjectContext project,
    GraphBuilder graph,
    ResolvedUnitResult unit,
  ) async {
    final errors = await unit.session.getErrors(unit.path);
    if (errors is! ErrorsResult) return;
    for (final diagnostic in errors.diagnostics) {
      final code = AnalyzerDiagnosticCollector.normalizeCode(
        diagnostic.diagnosticCode.lowerCaseUniqueName,
      );
      if (!AnalyzerDiagnosticCollector.supportedCodes.contains(code)) continue;
      final location = unit.lineInfo.getLocation(diagnostic.offset);
      _addUnusedDiagnosticNode(
        project,
        graph,
        path: unit.path,
        code: code,
        message: diagnostic.message,
        line: location.lineNumber,
        column: location.columnNumber,
        length: diagnostic.length,
        offset: diagnostic.offset,
      );
    }
  }

  void _addUnusedDiagnosticNode(
    ProjectContext project,
    GraphBuilder graph, {
    required String path,
    required String code,
    required String message,
    required int line,
    required int column,
    required int length,
    required int offset,
  }) {
    final relativePath = project.relative(path);
    graph.addNode(
      GraphNode(
        id:
            'dart-diagnostic:${project.packageName}/$relativePath'
            '#$code@$offset',
        kind: NodeKind.analyzerDiagnostic,
        origin: Uri.file(path),
        displayName: '$code at $relativePath:$line:$column',
        metadata: {
          'diagnosticCode': code,
          'message': message,
          'line': line,
          'column': column,
          'length': length,
          'removalSupported': false,
          'externallyAddressable': false,
        },
      ),
    );
  }
}

final class _NamedArgumentAtOffsetFinder extends RecursiveAstVisitor<void> {
  _NamedArgumentAtOffsetFinder(this.offset);

  final int offset;
  AstNode? match;

  @override
  void visitArgumentList(ArgumentList node) {
    for (final argument in node.arguments) {
      if (match == null &&
          isAnalyzerNamedArgument(argument) &&
          argument.offset <= offset &&
          offset < argument.offset + argument.length) {
        match = argument;
      }
    }
    super.visitArgumentList(node);
  }
}

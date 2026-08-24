import 'dart:io';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/error/error.dart';
import 'package:path/path.dart' as p;

import '../../core/graph/build_condition.dart';
import '../../core/graph/edge.dart';
import '../../core/graph/evidence.dart';
import '../../core/graph/execution_target.dart';
import '../../core/graph/node.dart';
import '../../core/project/project_context.dart';
import '../../core/project/target_matrix.dart';
import '../adapter_report_definition.dart';
import '../analyzer_adapter.dart';
import 'analyzer_ast_compat.dart';
import 'analyzer_diagnostic_collector.dart';
import 'dart_adapter_profile.dart';
import 'dart_analysis_workspace.dart';
import 'dart_directive_resolver.dart';
import 'dart_execution_context_service.dart';
import 'dart_execution_reachability_service.dart';
import 'dart_ids.dart';
import 'dart_package_ownership.dart';
import 'declaration_visitor.dart';
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
    final workspace = DartAnalysisWorkspace(project);
    final contexts = await DefaultDartExecutionContextService(
      workspace: workspace,
    ).resolve(project);
    await _analyze(
      project,
      graph,
      workspace,
      DefaultDartExecutionReachabilityService(
        workspace: workspace,
        contexts: contexts,
      ),
    );
  }

  @override
  Future<void> analyzeWithServices(
    ProjectContext project,
    GraphBuilder graph,
    AdapterServices services,
  ) async {
    final workspace = services.dartWorkspace ?? DartAnalysisWorkspace(project);
    final reachabilityService =
        services.dartExecutionReachabilityService ??
        DefaultDartExecutionReachabilityService(
          workspace: workspace,
          contexts:
              await (services.dartExecutionContextService ??
                      DefaultDartExecutionContextService(workspace: workspace))
                  .resolve(project),
        );
    await _analyze(
      project,
      graph,
      workspace,
      reachabilityService,
      profile: services.dartProfile,
    );
  }

  Future<void> _analyze(
    ProjectContext project,
    GraphBuilder graph,
    DartAnalysisWorkspace workspace,
    DartExecutionReachabilityService reachabilityService, {
    DartAdapterProfile? profile,
  }) async {
    final ownership = DartPackageOwnership.discover(project);
    final reachability = await reachabilityService.resolve(project);
    _mirrorExecutionContexts(project, graph, reachability.contexts);
    final cliDiagnosticsFuture = profile == null
        ? _collectAnalyzerDiagnostics(project)
        : profile.measureAsync(
            'cliDiagnostics',
            () => _collectAnalyzerDiagnostics(project),
          );

    final modeledPaths = <String>{};
    final unresolvedReferenceIndex = UnresolvedReferenceIndex(project);
    final unresolvedReferences = <UnresolvedReferenceFact>{};
    final generatedUnresolvedReferences = <UnresolvedReferenceFact>{};
    final externalClosureSeeds = _ExternalClosureSeeds(workspace);

    final resolvedLibraries = reachability.resolvedLibraries;
    final selectedLibraryClosureIds = _selectedLibraryClosureIds(
      project,
      reachability,
      ownership,
    );
    final selectedNodeIdsByLibraryId = <String, Set<String>>{};
    for (final library in resolvedLibraries) {
      final filePath = library.element.firstFragment.source.fullName;
      final owner = ownership.ownerOf(filePath);
      final isModeled = DartIds.isModeledProjectPath(
        project,
        filePath,
        ownership: ownership,
      );
      final isGenerated = DartIds.isGeneratedProjectPath(
        project,
        filePath,
        ownership: ownership,
      );
      if (!isModeled && !isGenerated) {
        if (owner.ownership == DartSourceOwnership.unknown) {
          graph.addBlocker(
            reason: 'Dart ownership boundary is unknown',
            affectedNamespace: 'dart:${project.packageName}/',
          );
        }
        continue;
      }

      if (!isModeled) {
        _recordGeneratedLibrary(
          project,
          graph,
          library,
          filePath,
          generatedUnresolvedReferences,
          ownership,
        );
        final generatedLibraryId = _selectedLibraryNodeId(
          project,
          library.element,
          ownership,
        );
        selectedNodeIdsByLibraryId[generatedLibraryId] = {generatedLibraryId};
        continue;
      }

      modeledPaths.addAll(library.units.map((unit) => unit.path));

      Future<void> analyzeLibrary() => _analyzeLibrary(
        project,
        graph,
        library,
        unresolvedReferenceIndex,
        unresolvedReferences,
        generatedUnresolvedReferences,
        externalClosureSeeds: externalClosureSeeds,
        affectedSelectedLibraryIds:
            selectedLibraryClosureIds[_canonicalDartPath(filePath)] ??
            {_selectedLibraryNodeId(project, library.element, ownership)},
        selectedNodeIdsByLibraryId: selectedNodeIdsByLibraryId,
        workspace: workspace,
        ownership: ownership,
        profile: profile,
      );
      if (profile == null) {
        await analyzeLibrary();
      } else {
        await profile.measureAsync('analyzeLibrary', analyzeLibrary);
      }
    }

    await _admitExecutionSelectedExternalLibraries(
      project,
      graph,
      workspace,
      ownership,
      reachability,
      selectedLibraryClosureIds,
      selectedNodeIdsByLibraryId,
      externalClosureSeeds,
    );
    await _inspectExternalClosure(
      project,
      graph,
      workspace,
      ownership,
      externalClosureSeeds,
      selectedNodeIdsByLibraryId,
    );

    void emitExecutionReachability() =>
        _emitExecutionReachability(project, graph, reachability, ownership);
    if (profile == null) {
      emitExecutionReachability();
    } else {
      profile.measure('executionGraphEmission', emitExecutionReachability);
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

    _addEmptyFiles(project, graph, modeledPaths, ownership);

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
        if (!DartIds.isModeledProjectPath(
          project,
          diagnostic.path,
          ownership: ownership,
        )) {
          continue;
        }
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

  void _mirrorExecutionContexts(
    ProjectContext project,
    GraphBuilder graph,
    DartExecutionContextSnapshot snapshot,
  ) {
    final configuredTargets = snapshot.configuredTargets.toSet();
    if (configuredTargets.length != project.targets.toSet().length ||
        !configuredTargets.containsAll(project.targets)) {
      throw StateError(
        'The Dart execution-context snapshot does not match the project target matrix.',
      );
    }

    final auxiliaryById = {
      for (final target in snapshot.auxiliaryExecutionTargets)
        target.id: target,
    };
    for (final target in snapshot.auxiliaryExecutionTargets) {
      graph.addAuxiliaryExecutionTarget(target);
    }
    for (final root in snapshot.roots) {
      switch (root.domain) {
        case RootDomain.configuredTarget:
          graph.addRoot(
            root.nodeId,
            reason: root.reason,
            condition: BuildCondition.forTarget(root.configuredTarget!),
          );
        case RootDomain.auxiliary:
          final executionTarget =
              auxiliaryById[root.auxiliaryExecutionTargetId];
          if (executionTarget == null) {
            throw StateError(
              'Dart execution root names an unregistered auxiliary target.',
            );
          }
          graph.addAuxiliaryRoot(
            root.nodeId,
            reason: root.reason,
            executionTarget: executionTarget,
          );
      }
    }
    for (final issue in snapshot.issues) {
      final scopedIncompleteRoots = {
        for (final root in snapshot.roots)
          if (root.auxiliaryExecutionTargetId != null &&
              auxiliaryById[root.auxiliaryExecutionTargetId]
                      ?.environmentComplete ==
                  false)
            root.nodeId,
      };
      graph.addBlocker(
        reason: '${issue.code}: ${issue.reason}',
        affectedNodeIds: issue.requiresGlobalBlocker
            ? const {}
            : scopedIncompleteRoots,
      );
    }
  }

  void _emitExecutionReachability(
    ProjectContext project,
    GraphBuilder graph,
    DartExecutionReachabilitySnapshot snapshot,
    DartPackageOwnership ownership,
  ) {
    final libraryIdsByCanonicalPath = <String, String>{
      for (final library in snapshot.resolvedLibraries)
        _canonicalDartPath(library.element.firstFragment.source.fullName):
            _selectedLibraryNodeId(project, library.element, ownership),
    };
    for (final edge in snapshot.directives.edges) {
      final sourceOwner = ownership.ownerOf(edge.sourcePath);
      if (sourceOwner.ownership != DartSourceOwnership.selectedPackage) {
        graph.addBlocker(
          reason: 'Dart directive source ownership is incomplete',
          location: edge.sourcePath,
          affectedNamespace: 'dart:${project.packageName}/',
        );
        continue;
      }
      final sourceId = libraryIdsByCanonicalPath[edge.sourcePath];
      if (sourceId == null) {
        graph.addBlocker(
          reason: 'Dart directive source has no projected library node',
          location: edge.sourcePath,
          affectedNamespace: 'dart:${project.packageName}/',
        );
        continue;
      }
      final targetOwner = ownership.ownerOf(edge.targetPath);
      switch (targetOwner.ownership) {
        case DartSourceOwnership.selectedPackage:
          final targetId = libraryIdsByCanonicalPath[edge.targetPath];
          if (targetId == null) {
            graph.addBlocker(
              reason: 'Dart directive target has no projected library node',
              location: edge.targetPath,
              affectedNamespace: 'dart:${project.packageName}/',
            );
            continue;
          }
          graph.addEdge(
            GraphEdge(
              from: sourceId,
              to: targetId,
              kind: EdgeKind.imports,
              evidence: Evidence(
                kind: EvidenceKind.semanticReference,
                producer: 'dart',
                description: edge.kind == DartDirectiveKind.import
                    ? 'execution-context import directive'
                    : 'execution-context export directive',
                exact: edge.exact,
                location: edge.sourcePath,
              ),
              condition: edge.condition,
            ),
          );
        case DartSourceOwnership.externalPackage:
          _addExternalPackageBoundaryEdge(
            project: project,
            graph: graph,
            sourceLibraryId: sourceId,
            owner: targetOwner,
            description: edge.kind == DartDirectiveKind.import
                ? 'external package import directive'
                : 'external package export directive',
            location: edge.sourcePath,
            condition: edge.condition,
            exact: edge.exact,
          );
        case DartSourceOwnership.unknown:
          graph.addBlocker(
            reason: 'Dart ownership boundary is unknown',
            location: edge.targetPath,
            affectedNamespace: 'dart:${project.packageName}/',
          );
      }
    }
    for (final edge in snapshot.publicSurface.edges) {
      graph.addEdge(
        GraphEdge(
          from: edge.publicEntrypointLibraryId,
          to: edge.declarationId,
          kind: EdgeKind.references,
          evidence: Evidence(
            kind: EvidenceKind.configuration,
            producer: 'dart',
            description: 'public package API',
            exact: edge.exact,
            location: edge.publicEntrypointLibraryId,
          ),
          condition: edge.condition,
        ),
      );
    }
    for (final issue in snapshot.directives.issues) {
      graph.addBlocker(
        reason: issue.reason,
        location: issue.sourcePath,
        affectedNamespace: 'dart:${project.packageName}/',
      );
    }
    for (final issue in snapshot.publicSurface.issues) {
      graph.addBlocker(
        reason: issue.reason,
        location: issue.sourcePath,
        affectedNamespace: 'dart:${project.packageName}/',
      );
    }
    for (final issue in snapshot.issues) {
      graph.addBlocker(
        reason: issue,
        affectedNamespace: 'dart:${project.packageName}/',
      );
    }
  }

  Future<void> _admitExecutionSelectedExternalLibraries(
    ProjectContext project,
    GraphBuilder graph,
    DartAnalysisWorkspace workspace,
    DartPackageOwnership ownership,
    DartExecutionReachabilitySnapshot snapshot,
    Map<String, Set<String>> selectedLibraryClosureIds,
    Map<String, Set<String>> selectedNodeIdsByLibraryId,
    _ExternalClosureSeeds externalClosureSeeds,
  ) async {
    final selectedLibrariesByPath = <String, LibraryElement>{
      for (final library in snapshot.resolvedLibraries)
        _canonicalDartPath(library.element.firstFragment.source.fullName):
            library.element,
    };
    final admittedDirectives = <String>{};
    for (final edge in snapshot.directives.edges) {
      if (!_edgeSourceIsRetained(snapshot, edge)) continue;
      if (ownership.ownerOf(edge.targetPath).ownership !=
          DartSourceOwnership.externalPackage) {
        continue;
      }
      final sourcePath = _canonicalDartPath(edge.sourcePath);
      final targetPath = _canonicalDartPath(edge.targetPath);
      if (!admittedDirectives.add('$sourcePath|$targetPath')) continue;
      final affectedSelectedLibraryIds = selectedLibraryClosureIds[sourcePath];
      if (affectedSelectedLibraryIds == null ||
          affectedSelectedLibraryIds.isEmpty) {
        graph.addBlocker(
          reason: 'Dart directive source has no projected library node',
          location: edge.sourcePath,
          affectedNamespace: 'dart:${project.packageName}/',
        );
        continue;
      }
      final fromLibrary = selectedLibrariesByPath[sourcePath];
      if (fromLibrary == null) {
        graph.addBlocker(
          reason: 'Dart directive source has no projected library node',
          location: edge.sourcePath,
          affectedNamespace: 'dart:${project.packageName}/',
        );
        continue;
      }
      final SomeResolvedLibraryResult result;
      try {
        result = await workspace.resolveSelectedDirectiveTarget(
          targetPath,
          fromLibrary: fromLibrary,
        );
      } on Object {
        final affectedNodeIds = _affectedSelectedNodeIds(
          affectedSelectedLibraryIds,
          selectedNodeIdsByLibraryId,
        );
        graph.addBlocker(
          reason: 'external package closure could not be inspected',
          location: targetPath,
          affectedNamespace: affectedNodeIds == null
              ? 'dart:${project.packageName}/'
              : null,
          affectedNodeIds: affectedNodeIds ?? const <String>{},
        );
        continue;
      }
      if (result is! ResolvedLibraryResult) {
        final affectedNodeIds = _affectedSelectedNodeIds(
          affectedSelectedLibraryIds,
          selectedNodeIdsByLibraryId,
        );
        graph.addBlocker(
          reason: 'external package closure could not be inspected',
          location: targetPath,
          affectedNamespace: affectedNodeIds == null
              ? 'dart:${project.packageName}/'
              : null,
          affectedNodeIds: affectedNodeIds ?? const <String>{},
        );
        continue;
      }
      externalClosureSeeds.add(
        result.element,
        affectedSelectedLibraryIds: affectedSelectedLibraryIds,
      );
    }
  }

  Future<void> _inspectExternalClosure(
    ProjectContext project,
    GraphBuilder graph,
    DartAnalysisWorkspace workspace,
    DartPackageOwnership ownership,
    _ExternalClosureSeeds seeds,
    Map<String, Set<String>> selectedNodeIdsByLibraryId,
  ) async {
    final elements = Map<String, LibraryElement>.of(seeds.elements);
    final affectedLibraryIds = {
      for (final entry in seeds.affectedSelectedLibraryIds.entries)
        entry.key: Set<String>.of(entry.value),
    };
    final propagatedLibraryIds = <String, Set<String>>{};
    final dependencies = <String, Set<String>>{};
    final boundedIssues = <String, List<_ExternalClosureIssue>>{};
    final graphIssues = <String, List<_ExternalGraphIssue>>{};
    final inspected = <String>{};
    final pending = <String>{...elements.keys};

    while (pending.isNotEmpty) {
      final identity = pending.reduce(
        (left, right) => left.compareTo(right) <= 0 ? left : right,
      );
      pending.remove(identity);
      final element = elements[identity]!;
      final propagated = propagatedLibraryIds.putIfAbsent(
        identity,
        () => <String>{},
      );
      final delta = (affectedLibraryIds[identity] ?? const <String>{})
          .difference(propagated);
      if (delta.isEmpty) continue;
      propagated.addAll(delta);

      if (inspected.add(identity)) {
        final source = element.firstFragment.source;
        final owner = ownership.ownerOf(source.fullName);
        if (owner.ownership == DartSourceOwnership.unknown) {
          workspace.recordUnknownOwnershipBoundary(source.fullName);
          (graphIssues[identity] ??= []).add(
            _ExternalGraphIssue(
              reason: 'Dart ownership boundary is unknown',
              location: source.fullName,
            ),
          );
          continue;
        }
        if (owner.ownership != DartSourceOwnership.externalPackage) continue;

        final SomeResolvedLibraryResult result;
        try {
          result = await workspace.resolveBoundedClosureLibrary(element);
        } on Object {
          (boundedIssues[identity] ??= []).add(
            _ExternalClosureIssue(
              library: element,
              kind: DartBoundedClosureIssueKind.uninspectable,
              reason: 'external package closure could not be inspected',
              location: source.fullName,
            ),
          );
          continue;
        }
        if (result is! ResolvedLibraryResult) {
          (boundedIssues[identity] ??= []).add(
            _ExternalClosureIssue(
              library: element,
              kind: DartBoundedClosureIssueKind.uninspectable,
              reason: 'external package closure could not be inspected',
              location: source.fullName,
            ),
          );
          continue;
        }
        if (result.units.any(
          (unit) => unit.diagnostics.any(
            (diagnostic) =>
                diagnostic.diagnosticCode.severity == DiagnosticSeverity.ERROR,
          ),
        )) {
          (boundedIssues[identity] ??= []).add(
            _ExternalClosureIssue(
              library: element,
              kind: DartBoundedClosureIssueKind.uninspectable,
              reason: 'external package closure could not be inspected',
              location: source.fullName,
            ),
          );
        }
        final conditionalPaths =
            result.units
                .where(
                  (unit) => unit.unit.directives.any(_hasConditionalDirective),
                )
                .map((unit) => unit.path)
                .toList()
              ..sort();
        if (conditionalPaths.isNotEmpty) {
          (boundedIssues[identity] ??= []).add(
            _ExternalClosureIssue(
              library: element,
              kind: DartBoundedClosureIssueKind.conditionalDirective,
              reason:
                  'conditional Dart imports/exports are not modelled per target',
              location: conditionalPaths.first,
            ),
          );
        }

        final externalDependencies = dependencies.putIfAbsent(
          identity,
          () => <String>{},
        );
        final libraryDependencies = <LibraryElement>{
          ...result.element.firstFragment.importedLibraries,
          ...result.element.exportedLibraries,
        };
        for (final dependency in libraryDependencies) {
          final dependencySource = dependency.firstFragment.source;
          if (dependencySource.uri.isScheme('dart')) continue;
          final dependencyOwner = ownership.ownerOf(dependencySource.fullName);
          switch (dependencyOwner.ownership) {
            case DartSourceOwnership.selectedPackage:
              if (_isCoveredExternalEntrypoint(
                project,
                dependencySource.fullName,
              )) {
                continue;
              }
              graph.addBlocker(
                reason: 'external package can address selected Dart library',
                location: source.fullName,
                affectedNamespace: _selectedLibraryNodeId(
                  project,
                  dependency,
                  ownership,
                ),
              );
            case DartSourceOwnership.externalPackage:
              final dependencyIdentity = workspace.libraryIdentity(dependency);
              elements.putIfAbsent(dependencyIdentity, () => dependency);
              externalDependencies.add(dependencyIdentity);
            case DartSourceOwnership.unknown:
              workspace.recordUnknownOwnershipBoundary(
                dependencySource.fullName,
              );
              (graphIssues[identity] ??= []).add(
                _ExternalGraphIssue(
                  reason: 'Dart ownership boundary is unknown',
                  location: dependencySource.fullName,
                ),
              );
          }
        }
      }

      for (final dependencyIdentity
          in dependencies[identity] ?? const <String>{}) {
        final dependencyScopes = affectedLibraryIds.putIfAbsent(
          dependencyIdentity,
          () => <String>{},
        );
        final previousLength = dependencyScopes.length;
        dependencyScopes.addAll(delta);
        if (dependencyScopes.length != previousLength) {
          pending.add(dependencyIdentity);
        }
      }
    }

    final identities = affectedLibraryIds.keys.toList()..sort();
    for (final identity in identities) {
      final affectedNodeIds = _affectedSelectedNodeIds(
        affectedLibraryIds[identity] ?? const <String>{},
        selectedNodeIdsByLibraryId,
      );
      for (final issue
          in boundedIssues[identity] ?? const <_ExternalClosureIssue>[]) {
        _addExternalClosureIssue(
          project,
          graph,
          workspace,
          issue.library,
          kind: issue.kind,
          reason: issue.reason,
          location: issue.location,
          affectedNodeIds: affectedNodeIds,
        );
      }
      for (final issue
          in graphIssues[identity] ?? const <_ExternalGraphIssue>[]) {
        graph.addBlocker(
          reason: issue.reason,
          location: issue.location,
          affectedNamespace: affectedNodeIds == null
              ? 'dart:${project.packageName}/'
              : null,
          affectedNodeIds: affectedNodeIds ?? const <String>{},
        );
      }
    }
  }

  void _addExternalClosureIssue(
    ProjectContext project,
    GraphBuilder graph,
    DartAnalysisWorkspace workspace,
    LibraryElement library, {
    required DartBoundedClosureIssueKind kind,
    required String reason,
    required String location,
    required Set<String>? affectedNodeIds,
  }) {
    workspace.recordBoundedClosureIssue(
      library: library,
      kind: kind,
      location: location,
    );
    graph.addBlocker(
      reason: reason,
      location: location,
      affectedNamespace: affectedNodeIds == null
          ? 'dart:${project.packageName}/'
          : null,
      affectedNodeIds: affectedNodeIds ?? const {},
    );
  }

  Set<String>? _affectedSelectedNodeIds(
    Set<String> affectedLibraryIds,
    Map<String, Set<String>> selectedNodeIdsByLibraryId,
  ) {
    if (affectedLibraryIds.isEmpty) return null;
    final nodeIds = <String>{};
    for (final libraryId in affectedLibraryIds) {
      final libraryNodeIds = selectedNodeIdsByLibraryId[libraryId];
      if (libraryNodeIds == null || libraryNodeIds.isEmpty) return null;
      nodeIds.addAll(libraryNodeIds);
    }
    return nodeIds.isEmpty ? null : nodeIds;
  }

  bool _isCoveredExternalEntrypoint(
    ProjectContext project,
    String libraryPath,
  ) {
    final relativePath = project.relative(libraryPath);
    if (project.rootCoverage.publicEntrypoints.contains(relativePath)) {
      return true;
    }
    return project.rootCoverage.mode == RootCoverageMode.inferred &&
        relativePath == 'lib/${project.packageName}.dart';
  }

  String _selectedLibraryNodeId(
    ProjectContext project,
    LibraryElement library,
    DartPackageOwnership ownership,
  ) {
    final path = library.firstFragment.source.fullName;
    if (ownership.isSelectedGeneratedSource(path)) {
      return DartIds.generatedArtifact(project, path);
    }
    return DartIds.library(project, library, ownership: ownership);
  }

  Map<String, Set<String>> _selectedLibraryClosureIds(
    ProjectContext project,
    DartExecutionReachabilitySnapshot snapshot,
    DartPackageOwnership ownership,
  ) {
    final libraryIdsByPath = <String, String>{};
    for (final library in snapshot.resolvedLibraries) {
      final path = library.element.firstFragment.source.fullName;
      if (ownership.ownerOf(path).ownership !=
          DartSourceOwnership.selectedPackage) {
        continue;
      }
      libraryIdsByPath[_canonicalDartPath(path)] = _selectedLibraryNodeId(
        project,
        library.element,
        ownership,
      );
    }

    final outgoing = <String, Set<String>>{
      for (final path in libraryIdsByPath.keys) path: <String>{},
    };
    for (final edge in snapshot.directives.edges) {
      final sourcePath = _canonicalDartPath(edge.sourcePath);
      final targetPath = _canonicalDartPath(edge.targetPath);
      if (!libraryIdsByPath.containsKey(sourcePath) ||
          !libraryIdsByPath.containsKey(targetPath)) {
        continue;
      }
      outgoing[sourcePath]!.add(targetPath);
    }

    return {
      for (final sourcePath in libraryIdsByPath.keys)
        sourcePath: {
          for (final reachedPath in _pathClosure(sourcePath, outgoing))
            libraryIdsByPath[reachedPath]!,
        },
    };
  }

  Set<String> _pathClosure(
    String sourcePath,
    Map<String, Set<String>> outgoing,
  ) {
    final reached = <String>{sourcePath};
    final pending = <String>[sourcePath];
    while (pending.isNotEmpty) {
      final current = pending.removeLast();
      for (final target in outgoing[current] ?? const <String>{}) {
        if (reached.add(target)) pending.add(target);
      }
    }
    return reached;
  }

  void _recordGeneratedLibrary(
    ProjectContext project,
    GraphBuilder graph,
    Object library,
    String filePath,
    Set<UnresolvedReferenceFact> unresolvedReferences,
    DartPackageOwnership ownership,
  ) {
    if (library is NotLibraryButPartResult) return;
    if (library is! ResolvedLibraryResult) {
      graph.addBlocker(
        reason: 'analyzer could not resolve a generated Dart library',
        location: filePath,
      );
      return;
    }

    final generatedLibraryId = DartIds.generatedArtifact(project, filePath);
    graph.addNode(
      GraphNode(
        id: generatedLibraryId,
        kind: NodeKind.generatedArtifact,
        displayName: '<generated library>',
        origin: Uri.file(filePath),
        metadata: const {
          'declarationCount': 0,
          'directiveCount': 0,
          'generatedPartPaths': <String>[],
          'externallyAddressable': false,
          'removalSupported': false,
          'generated': true,
        },
      ),
    );

    final affectedNodeIds = <String>{};
    var hasErrors = false;
    for (final unit in library.units) {
      final collector = GeneratedReferenceCollector(project: project)
        ..visitLibrary(unit.unit);
      affectedNodeIds.addAll(collector.affectedNodeIds);
      final unresolvedCollector = ReferenceCollector(
        project: project,
        graph: graph,
        libraryId: generatedLibraryId,
        location: unit.path,
        collapseCallerToLibrary: true,
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
    DartPackageOwnership ownership,
  ) {
    for (final file in project.dartFiles) {
      if (!DartIds.isModeledProjectPath(
            project,
            file.path,
            ownership: ownership,
          ) ||
          modeledPaths.contains(file.path)) {
        continue;
      }
      final parsed = parseString(
        content: file.readAsStringSync(),
        path: file.path,
        featureSet: project.dartFeatureSet,
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
          id: DartIds.libraryPath(project, file.path, ownership: ownership),
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
    UnresolvedReferenceIndex unresolvedReferenceIndex,
    Set<UnresolvedReferenceFact> unresolvedReferences,
    Set<UnresolvedReferenceFact> generatedUnresolvedReferences, {
    required _ExternalClosureSeeds externalClosureSeeds,
    required Set<String> affectedSelectedLibraryIds,
    required Map<String, Set<String>> selectedNodeIdsByLibraryId,
    required DartAnalysisWorkspace workspace,
    required DartPackageOwnership ownership,
    DartAdapterProfile? profile,
  }) async {
    final libraryElement = library.element;
    final libraryId = DartIds.library(
      project,
      libraryElement,
      ownership: ownership,
    );
    final selectedNodeIds = selectedNodeIdsByLibraryId.putIfAbsent(
      libraryId,
      () => {libraryId},
    );

    final editableUnits = library.units
        .where(
          (unit) => DartIds.isModeledProjectPath(
            project,
            unit.path,
            ownership: ownership,
          ),
        )
        .toList(growable: false);
    final generatedPartPaths = library.units
        .where(
          (unit) => DartIds.isGeneratedProjectPath(
            project,
            unit.path,
            ownership: ownership,
          ),
        )
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

    // Element-model dependency lists validate the bounded external closure;
    // they are never an import/export edge source.
    for (final dependency in <LibraryElement>{
      ...libraryElement.firstFragment.importedLibraries,
      ...libraryElement.exportedLibraries,
    }) {
      final source = dependency.firstFragment.source;
      if (source.uri.isScheme('dart')) continue;
      final owner = ownership.ownerOf(source.fullName);
      if (owner.ownership == DartSourceOwnership.externalPackage) {
        externalClosureSeeds.add(
          dependency,
          affectedSelectedLibraryIds: affectedSelectedLibraryIds,
        );
      } else if (owner.ownership == DartSourceOwnership.unknown) {
        workspace.recordUnknownOwnershipBoundary(source.fullName);
        graph.addBlocker(
          reason: 'Dart ownership boundary is unknown',
          affectedNamespace: 'dart:${project.packageName}/',
        );
      }
    }

    // Visit each unit to collect declarations.
    // A library may include part files (e.g., .g.dart) that should be
    // excluded.  Apply the same exclusion list per-unit, not only at the
    // top-level library path.
    for (final unit in library.units) {
      final unitOwner = ownership.ownerOf(unit.path);
      if (!DartIds.isModeledProjectPath(
        project,
        unit.path,
        ownership: ownership,
      )) {
        if (DartIds.isGeneratedProjectPath(
          project,
          unit.path,
          ownership: ownership,
        )) {
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
            collapseCallerToLibrary: true,
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
        } else if (unitOwner.ownership == DartSourceOwnership.externalPackage) {
          graph.addBlocker(
            reason: 'selected Dart library includes a non-selected part',
            location: unit.path,
            affectedNamespace: libraryId,
          );
        } else if (unitOwner.ownership == DartSourceOwnership.unknown) {
          graph.addBlocker(
            reason:
                'selected Dart library includes a part with unknown ownership',
            location: unit.path,
            affectedNamespace: libraryId,
          );
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
      selectedNodeIds.addAll(visitor.declarationIds);

      if (profile == null) {
        await _addUnusedDiagnostics(project, graph, unit);
      } else {
        await profile.measureAsync(
          'sessionDiagnostics',
          () => _addUnusedDiagnostics(project, graph, unit),
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

  void _addExternalPackageBoundaryEdge({
    required ProjectContext project,
    required GraphBuilder graph,
    required String sourceLibraryId,
    required DartSourceOwner owner,
    required String description,
    required String? location,
    BuildCondition condition = BuildCondition.unconditional,
    bool exact = true,
  }) {
    final packageName = owner.packageName;
    if (packageName == null || packageName.isEmpty) {
      graph.addBlocker(
        reason: 'Dart ownership boundary is unknown',
        affectedNamespace: 'dart:${project.packageName}/',
      );
      return;
    }
    final boundaryId = DartIds.packageBoundary(project, packageName);
    graph.addNode(
      GraphNode(
        id: boundaryId,
        kind: NodeKind.package,
        origin: Uri.parse('package:$packageName/'),
        displayName: packageName,
        metadata: {'packageName': packageName, 'externalBoundary': true},
      ),
    );
    graph.addEdge(
      GraphEdge(
        from: sourceLibraryId,
        to: boundaryId,
        kind: EdgeKind.imports,
        evidence: Evidence(
          kind: EvidenceKind.semanticReference,
          producer: 'dart',
          description: description,
          exact: exact,
          location: location,
        ),
        condition: condition,
      ),
    );
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

final class _ExternalClosureSeeds {
  _ExternalClosureSeeds(this._workspace);

  final DartAnalysisWorkspace _workspace;
  final Map<String, LibraryElement> elements = {};
  final Map<String, Set<String>> affectedSelectedLibraryIds = {};

  void add(
    LibraryElement element, {
    required Set<String> affectedSelectedLibraryIds,
  }) {
    final identity = _workspace.libraryIdentity(element);
    elements.putIfAbsent(identity, () => element);
    (this.affectedSelectedLibraryIds[identity] ??= {}).addAll(
      affectedSelectedLibraryIds,
    );
  }
}

final class _ExternalClosureIssue {
  const _ExternalClosureIssue({
    required this.library,
    required this.kind,
    required this.reason,
    required this.location,
  });

  final LibraryElement library;
  final DartBoundedClosureIssueKind kind;
  final String reason;
  final String location;
}

final class _ExternalGraphIssue {
  const _ExternalGraphIssue({required this.reason, required this.location});

  final String reason;
  final String location;
}

bool _edgeSourceIsRetained(
  DartExecutionReachabilitySnapshot snapshot,
  DartDirectiveEdge edge,
) {
  for (final target in edge.condition.exactTargets) {
    if (snapshot.configuredRetainedUnitPaths[target]?.contains(
          edge.sourcePath,
        ) ??
        false) {
      return true;
    }
  }
  for (final target in edge.condition.exactAuxiliaryTargets) {
    if (snapshot.auxiliaryRetainedUnitPaths[target.id]?.contains(
          edge.sourcePath,
        ) ??
        false) {
      return true;
    }
  }
  return false;
}

String _canonicalDartPath(String path) {
  final absolute = p.normalize(p.absolute(path));
  try {
    return p.normalize(File(absolute).resolveSymbolicLinksSync());
  } on FileSystemException {
    return absolute;
  }
}

bool _hasConditionalDirective(Directive directive) =>
    directive is ImportDirective && directive.configurations.isNotEmpty ||
    directive is ExportDirective && directive.configurations.isNotEmpty;

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

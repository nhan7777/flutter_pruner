// Copy this file to lib/src/adapters/<your_domain>/<your_domain>_adapter.dart
// and work through the numbered steps. Delete the guidance comments as you go.
//
// This file lives under doc/ and is excluded from analysis, so it will not
// break the build while it still contains placeholders.

import 'package:flutter_pruner/flutter_pruner.dart';

/// Analyzes <one domain> and contributes its nodes and edges to the graph.
///
/// Describe here, in two or three sentences, what this adapter can and cannot
/// see. The "cannot" half matters more: it tells the next maintainer which
/// false-negative reports are known limitations rather than bugs.
class MyDomainAdapter extends AnalyzerAdapter {
  /// Adapters hold no mutable state, so they can be const.
  const MyDomainAdapter();

  /// Stable identifier. Used in `--adapter` flags, report output and
  /// `dependsOn` declarations, so treat it as public API once released.
  @override
  String get id => 'my_domain';

  /// Human-readable name shown in progress output.
  @override
  String get name => 'My domain analyzer';

  /// Presentation-only metadata for the findings and measurements this
  /// adapter owns. Keep raw ids stable: reports snapshot labels separately.
  @override
  AdapterReportDefinition get reportDefinition => const AdapterReportDefinition(
    adapterId: 'my_domain',
    displayName: 'My domain analyzer',
    description: 'Explains what this adapter reports and its analysis scope.',
    findings: [
      AdapterFindingReportDefinition(
        nodeKind: NodeKind.declaration,
        ruleId: 'PRN-MYDOMAIN-001',
        title: 'Unused example',
        nodeLabel: 'Example',
        description: 'An example with no path from the configured roots.',
        measurementKind: 'my-domain-source-bytes',
        details: [
          AdapterReportDetailDefinition(
            key: 'sourcePath',
            label: 'Source path',
            valueType: AdapterReportDetailValueType.path,
            description: 'Project-relative source path for this example.',
          ),
        ],
      ),
    ],
    measurements: [
      AdapterReportMeasurementDefinition(
        kind: 'my-domain-source-bytes',
        label: 'My domain source size',
        unit: 'bytes',
        description: 'Source bytes associated with the reported example.',
      ),
    ],
  );

  /// Prefer an empty list. Dependencies force an execution order and make the
  /// adapter harder to test in isolation. Declare one only if you genuinely
  /// need nodes another adapter created.
  @override
  List<String> get dependsOn => const <String>[];

  /// Cheap check so irrelevant projects skip this adapter entirely.
  /// Base it on a dependency, a config file or a directory — never on parsing.
  @override
  bool appliesTo(ProjectContext project) => project.hasDependency('my_package');

  @override
  Future<void> analyze(ProjectContext project, GraphBuilder graph) async {
    // ------------------------------------------------------------------
    // 1. Declare nodes: the things a user might want to delete.
    //
    // Use a scheme-prefixed id, and derive paths through project.relative()
    // so ids stay identical across machines and CI runs.
    // ------------------------------------------------------------------
    graph.addNode(
      GraphNode(
        id: 'my_domain:${project.packageName}:example',
        kind: NodeKind.declaration,
        displayName: 'example',
        origin: Uri.file(project.resolve('lib/example.dart')),
        metadata: const {'sourcePath': 'lib/example.dart'},
        // Fill sizeBytes only when it reflects real on-disk bytes.
        // Leave it null rather than estimating.
      ),
    );

    // ------------------------------------------------------------------
    // 2. Add edges: "A keeps B alive".
    //
    // Resolve the reference through the analyzer's element model. Do not
    // match source text: comments, tests and changelogs all contain strings
    // that look like references but keep nothing alive.
    //
    // exact: true means you resolved exactly one unambiguous target.
    // ------------------------------------------------------------------
    graph.addReference(
      from: 'dart:${project.packageName}/lib/main.dart#main',
      to: 'my_domain:${project.packageName}:example',
      kind: EdgeKind.references,
      evidence: graph.evidence(
        kind: EvidenceKind.semanticReference,
        description: 'resolved call to example()',
        exact: true,
      ),
    );

    // ------------------------------------------------------------------
    // 3. Add roots and protection for anything reachable from outside
    //    the Dart call graph.
    //
    // Be generous here. A missing root produces a confident, wrong deletion;
    // an unnecessary root only produces a missed finding.
    //
    // Root      = reachability starts here.
    // Protected = never auto-deletable, even with zero references.
    // ------------------------------------------------------------------
    graph.addRoot(
      'my_domain:${project.packageName}:example',
      reason: 'invoked by the platform, not by Dart code',
    );

    graph.protect(
      'my_domain:${project.packageName}:example',
      reason: 'declared in a manifest the tool cannot rewrite safely',
    );

    // ------------------------------------------------------------------
    // 4. Record a blocker for every construct you could not resolve.
    //
    // This is the step that separates a trustworthy tool from a dangerous
    // one. "I found no reference" and "I could not see the reference" lead
    // to opposite actions, and only a blocker distinguishes them.
    //
    // Scope it with affectedNamespace or affectedNodeIds when possible.
    // An unscoped blocker protects everything and makes the run useless.
    // ------------------------------------------------------------------
    graph.addBlocker(
      reason: 'identifier built from a non-constant expression',
      affectedNamespace: 'my_domain:${project.packageName}:',
      // location: SourceLocation(...) — always include when you have it,
      // so the user can inspect the exact call site and decide.
    );
  }
}

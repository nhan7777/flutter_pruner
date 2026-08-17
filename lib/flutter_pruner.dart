/// Semantic auditor for Flutter/Dart projects.
///
/// This library exposes the pieces an adapter author needs: the graph model,
/// the confidence model, the project context and the adapter contract.
///
/// See `doc/contributing/how-to-add-adapter.md` to add a new analyzer.
library;

export 'src/adapters/adapter_report_definition.dart';
export 'src/adapters/analyzer_adapter.dart';
export 'src/adapters/dart/dart_adapter_profile.dart';
export 'src/adapters/dart/dart_analysis_workspace.dart';
export 'src/adapters/registry.dart';
export 'src/apply/finding_selection.dart';
export 'src/core/confidence/action_capability.dart';
export 'src/core/confidence/classification_reason.dart';
export 'src/core/confidence/confidence.dart';
export 'src/core/confidence/confidence_classifier.dart';
export 'src/core/confidence/finding.dart';
export 'src/core/confidence/finding_assessment.dart';
export 'src/core/graph/build_condition.dart';
export 'src/core/graph/edge.dart';
export 'src/core/graph/evidence.dart';
export 'src/core/graph/node.dart';
export 'src/core/graph/reachability_graph.dart';
export 'src/core/project/analysis_mode.dart';
export 'src/core/project/project_context.dart';
export 'src/core/project/project_path_policy.dart';
export 'src/core/project/target_matrix.dart';
export 'src/reporting/run_report.dart';
export 'src/verification/verification_policy.dart';

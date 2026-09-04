import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../core/graph/reachability_graph.dart';
import '../core/project/project_context.dart';
import 'finding_action_builder.dart';
import 'finding_selection.dart';
import 'removal_planner.dart';

/// Builds the immutable physical action projection of an authorized plan.
///
/// [RemovalPlan] remains the sole authority for logical units and blocks.
/// Graph and project inputs are used only to expand and canonicalize the
/// already-authorized physical actions.
final class ApplyActionPlanBuilder {
  /// Creates an action-plan builder with the core physical action expander.
  const ApplyActionPlanBuilder()
    : _actionBuilder = const FindingActionBuilder(),
      _validateCoreProjection = false;

  /// Creates a checked internal seam for action-projection tests.
  const ApplyActionPlanBuilder.forTesting(FindingActionBuilder actionBuilder)
    : _actionBuilder = actionBuilder,
      _validateCoreProjection = true;

  /// Expands one already-decided removal plan without revisiting actionability.
  ApplyActionPlan build({
    required RemovalPlan removalPlan,
    required ReachabilityGraph graph,
    required ProjectContext project,
    required FindingSelection selection,
  }) {
    final rawActionsByUnitId = <String, List<FindingActionDescriptor>>{};
    final coreActionsByUnitId = <String, List<FindingActionDescriptor>>{};
    for (final unit in removalPlan.units) {
      if (rawActionsByUnitId.containsKey(unit.id)) {
        throw StateError('Removal plan repeated atomic unit ID ${unit.id}.');
      }
      rawActionsByUnitId[unit.id] = _actionBuilder.build(
        findings: unit.findings,
        graph: graph,
        project: project,
        atomicGroup: unit.id,
      );
      if (_validateCoreProjection) {
        coreActionsByUnitId[unit.id] = const FindingActionBuilder().build(
          findings: unit.findings,
          graph: graph,
          project: project,
          atomicGroup: unit.id,
        );
      }
    }

    // Consumer-first library units can delete an importer before a dependency
    // unit runs. Bind that redundancy now; never rediscover it from existsSync
    // while executing the later unit.
    final wholeFileRemovalOrder = <String, int>{};
    for (var unitIndex = 0; unitIndex < removalPlan.units.length; unitIndex++) {
      for (final action
          in rawActionsByUnitId[removalPlan.units[unitIndex].id]!) {
        if (action.countsTowardSummary &&
            action.operation == FindingActionOperation.deleteFile) {
          wholeFileRemovalOrder[p.normalize(p.absolute(action.file.path))] =
              unitIndex;
        }
      }
    }

    final effectiveJournalIdentities = <String>{};
    final compositeActionIdentities = <String>{};
    final units = <ApplyActionPlanUnit>[];
    for (var unitIndex = 0; unitIndex < removalPlan.units.length; unitIndex++) {
      final unit = removalPlan.units[unitIndex];
      final findingIds = unit.findings
          .map((finding) => finding.node.id)
          .toList(growable: false);
      final authoritativeFindingsById = {
        for (final finding in unit.findings) finding.node.id: finding,
      };
      final actions = rawActionsByUnitId[unit.id]!
          .where((action) {
            if (action.operation != FindingActionOperation.cleanupImports) {
              return true;
            }
            final removalOrder =
                wholeFileRemovalOrder[p.normalize(
                  p.absolute(action.file.path),
                )];
            return removalOrder == null || removalOrder > unitIndex;
          })
          .toList(growable: false);

      for (final action in actions) {
        final authoritativeFinding =
            authoritativeFindingsById[action.finding.node.id];
        if (action.atomicGroup != unit.id || authoritativeFinding == null) {
          throw StateError(
            'Physical action projection does not belong to atomic unit '
            '${unit.id}: ${action.finding.node.id}.',
          );
        }
        if (!identical(action.finding, authoritativeFinding)) {
          throw StateError(
            'Physical action projection does not use the authoritative '
            'Finding instance for atomic unit ${unit.id}: '
            '${action.finding.node.id}.',
          );
        }
        final journalIdentity = action.findingId ?? action.finding.node.id;
        if (!effectiveJournalIdentities.add(journalIdentity)) {
          throw StateError(
            'Action plan repeated effective journal action identity '
            '$journalIdentity.',
          );
        }
        final compositeIdentity = jsonEncode([
          unit.id,
          action.finding.node.id,
          action.operation.name,
          p.normalize(p.absolute(action.file.path)),
          if (action.cleanupTargetPath == null)
            null
          else
            p.normalize(p.absolute(action.cleanupTargetPath!)),
        ]);
        if (!compositeActionIdentities.add(compositeIdentity)) {
          throw StateError(
            'Action plan repeated composite physical action identity for '
            '${action.finding.node.id} in ${unit.id}.',
          );
        }
      }
      for (final finding in unit.findings) {
        if (!actions.any((action) => identical(action.finding, finding))) {
          throw StateError(
            'Physical action projection for atomic unit ${unit.id} did not '
            'project physical work for authoritative finding '
            '${finding.node.id}.',
          );
        }
      }
      final coreActions = coreActionsByUnitId[unit.id];
      if (coreActions != null &&
          !_sameCoreActionProjection(
            rawActionsByUnitId[unit.id]!,
            coreActions,
          )) {
        throw StateError(
          'Physical action projection for atomic unit ${unit.id} does not '
          'match the core physical action projection.',
        );
      }

      units.add(
        ApplyActionPlanUnit._(
          order: unitIndex,
          id: unit.id,
          findingIds: findingIds,
          dependencyUnitIds: unit.dependencyUnitIds,
          actions: actions,
        ),
      );
    }

    final blocked = removalPlan.blocked
        .map(
          (item) => ApplyPlanBlock._(
            findingId: item.finding.node.id,
            reason: item.reason,
            blockedBy: item.blockedBy,
          ),
        )
        .toList(growable: false);
    final planFingerprint = units.isEmpty
        ? null
        : _planFingerprint(
            units,
            blocked: blocked,
            project: project,
            selection: selection,
          );
    return ApplyActionPlan._(
      planFingerprint: planFingerprint,
      units: units,
      blocked: blocked,
    );
  }

  // Alternate expanders are an internal test seam. Production always uses the
  // core builder; overrides must match that builder's physical provenance.
  final FindingActionBuilder _actionBuilder;
  final bool _validateCoreProjection;
}

/// Immutable initial or rescan action projection used by apply execution.
final class ApplyActionPlan {
  ApplyActionPlan._({
    required this.planFingerprint,
    required List<ApplyActionPlanUnit> units,
    required List<ApplyPlanBlock> blocked,
  }) : units = List<ApplyActionPlanUnit>.unmodifiable(units),
       blocked = List<ApplyPlanBlock>.unmodifiable(blocked),
       _actionsByUnitId =
           Map<String, List<FindingActionDescriptor>>.unmodifiable({
             for (final unit in units) unit.id: unit.actions,
           });

  /// Canonical topology encoding version retained by [planFingerprint].
  static const canonicalVersion = 1;

  /// Existing lowercase SHA-256 topology digest, or null for no active units.
  final String? planFingerprint;

  /// Logical units in the exact consumer-first order supplied by the planner.
  final List<ApplyActionPlanUnit> units;

  /// Planner blocks in their authoritative supplied order.
  final List<ApplyPlanBlock> blocked;

  final Map<String, List<FindingActionDescriptor>> _actionsByUnitId;

  /// Returns the frozen executor descriptors owned by [unitId].
  List<FindingActionDescriptor> actionsFor(String unitId) {
    final actions = _actionsByUnitId[unitId];
    if (actions == null) {
      throw StateError('Frozen action plan has no atomic unit $unitId.');
    }
    return actions;
  }
}

/// Immutable scalar and executor projection of one planner atomic unit.
final class ApplyActionPlanUnit {
  ApplyActionPlanUnit._({
    required this.order,
    required this.id,
    required List<String> findingIds,
    required List<String> dependencyUnitIds,
    required List<FindingActionDescriptor> actions,
  }) : findingIds = List<String>.unmodifiable(findingIds),
       dependencyUnitIds = List<String>.unmodifiable(dependencyUnitIds),
       actions = List<FindingActionDescriptor>.unmodifiable(actions);

  /// Zero-based physical plan order.
  final int order;

  /// Stable planner atomic-unit identity.
  final String id;

  /// Logical finding identities in authoritative planner order.
  final List<String> findingIds;

  /// Dependency unit identities in authoritative planner order.
  final List<String> dependencyUnitIds;

  /// Frozen physical descriptors in exact execution order.
  final List<FindingActionDescriptor> actions;
}

/// Immutable scalar projection of one planner-owned block.
final class ApplyPlanBlock {
  ApplyPlanBlock._({
    required this.findingId,
    required this.reason,
    required this.blockedBy,
  });

  /// Logical finding that is excluded from the plan.
  final String findingId;

  /// Planner-owned reason why removal is blocked.
  final PlanBlockReason reason;

  /// Retained graph identity that blocks removal.
  final String blockedBy;
}

bool _sameCoreActionProjection(
  List<FindingActionDescriptor> actual,
  List<FindingActionDescriptor> expected,
) {
  if (actual.length != expected.length) return false;
  String? normalizedPath(String? path) =>
      path == null ? null : p.normalize(p.absolute(path));

  for (var index = 0; index < actual.length; index++) {
    final actualAction = actual[index];
    final expectedAction = expected[index];
    if (!identical(actualAction.finding, expectedAction.finding) ||
        normalizedPath(actualAction.file.path) !=
            normalizedPath(expectedAction.file.path) ||
        actualAction.operation != expectedAction.operation ||
        actualAction.atomicGroup != expectedAction.atomicGroup ||
        actualAction.label != expectedAction.label ||
        actualAction.findingId != expectedAction.findingId ||
        actualAction.countsTowardSummary !=
            expectedAction.countsTowardSummary ||
        normalizedPath(actualAction.cleanupTargetPath) !=
            normalizedPath(expectedAction.cleanupTargetPath)) {
      return false;
    }
  }
  return true;
}

String _planFingerprint(
  List<ApplyActionPlanUnit> planUnits, {
  required List<ApplyPlanBlock> blocked,
  required ProjectContext project,
  required FindingSelection selection,
}) {
  String relativePath(String path) =>
      project.relative(p.normalize(p.absolute(path))).replaceAll('\\', '/');

  final units = <Map<String, Object?>>[];
  for (final unit in planUnits) {
    final findingIds = unit.findingIds.toList()..sort();
    final dependencies = unit.dependencyUnitIds.toList()..sort();
    units.add({
      'order': unit.order,
      'id': unit.id,
      'findingIds': findingIds,
      'dependencyUnitIds': dependencies,
      'actions': [
        for (
          var actionIndex = 0;
          actionIndex < unit.actions.length;
          actionIndex++
        )
          {
            'order': actionIndex,
            'logicalFindingId': unit.actions[actionIndex].finding.node.id,
            'journalFindingId':
                unit.actions[actionIndex].findingId ??
                unit.actions[actionIndex].finding.node.id,
            'operation': unit.actions[actionIndex].operation.name,
            'path': relativePath(unit.actions[actionIndex].file.path),
            'countsTowardSummary':
                unit.actions[actionIndex].countsTowardSummary,
            if (unit.actions[actionIndex].cleanupTargetPath != null)
              'cleanupTargetPath': relativePath(
                unit.actions[actionIndex].cleanupTargetPath!,
              ),
          },
      ],
    });
  }
  final blockedPayload =
      blocked
          .map(
            (item) => {
              'findingId': item.findingId,
              'reason': item.reason.name,
              'blockedBy': item.blockedBy,
            },
          )
          .toList()
        ..sort(
          (left, right) => (left['findingId'] as String).compareTo(
            right['findingId'] as String,
          ),
        );
  final payload = <String, Object?>{
    'version': 1,
    'selectionMode': selection.mode.name,
    'requestedFindingIds': selection.requestedFindingIds,
    'units': units,
    'blocked': blockedPayload,
  };
  return sha256.convert(utf8.encode(jsonEncode(payload))).toString();
}

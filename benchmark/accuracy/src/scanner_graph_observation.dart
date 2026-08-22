/// Strict, scanner-output-only graph observations for the accuracy oracle.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'accuracy_model.dart';
import 'oracle_project_path.dart';
import 'project_manifest.dart';

/// One immutable scanner-observed graph node. It carries no oracle truth.
final class ScannerGraphNodeObservation {
  /// Creates a node observation with a project-relative origin.
  ScannerGraphNodeObservation({
    required this.id,
    required this.kind,
    required this.projectRelativeOrigin,
  }) {
    if (id.isEmpty ||
        kind.isEmpty ||
        !isCanonicalProjectRelativePosixPath(projectRelativeOrigin)) {
      throw ArgumentError(
        'graph node identity, kind, and relative origin are required',
      );
    }
  }

  /// Exact scanner node ID.
  final String id;

  /// Exact scanner node kind, deliberately not a production enum.
  final String kind;

  /// Project-relative source origin reported by the scanner.
  final String projectRelativeOrigin;
}

/// Captured graph membership, kept separate from independently derived truth.
final class ScannerGraphObservation {
  /// Parses a strict v3 scanner graph observation.
  factory ScannerGraphObservation.fromJson(Map<String, Object?> json) =>
      _ScannerGraphReader(json).parse();

  /// Parses UTF-8 observation bytes and retains the exact raw SHA-256.
  factory ScannerGraphObservation.fromUtf8(List<int> bytes) {
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map) {
      throw const FormatException('graph observation must be an object');
    }
    final map = <String, Object?>{};
    for (final entry in decoded.entries) {
      if (entry.key is! String) {
        throw const FormatException('graph observation has non-string key');
      }
      map[entry.key as String] = entry.value;
    }
    return _ScannerGraphReader(
      map,
      rawSha256: sha256.convert(bytes).toString(),
    ).parse();
  }

  ScannerGraphObservation._({
    required this.version,
    required this.toolSha,
    required this.projectGitSha,
    required this.configSha256,
    required this.packageConfigSha256,
    required this.packageName,
    required this.projectRoot,
    required List<OracleTarget> configuredTargets,
    required List<OracleAuxiliaryExecutionTarget> auxiliaryExecutionTargets,
    required List<String> auxiliaryExecutionTargetIssues,
    required this.membershipAvailable,
    required List<ScannerGraphNodeObservation> nodes,
    required Map<String, Set<String>> provenByExecutionTarget,
    required Map<String, Set<String>> retainedByExecutionTarget,
    required List<String> issues,
    this.rawSha256,
  }) : configuredTargets = List.unmodifiable(List.from(configuredTargets)),
       auxiliaryExecutionTargets = List.unmodifiable(
         List.from(auxiliaryExecutionTargets),
       ),
       auxiliaryExecutionTargetIssues = List.unmodifiable(
         List.from(auxiliaryExecutionTargetIssues),
       ),
       nodes = List.unmodifiable(List.from(nodes)),
       provenByExecutionTarget = _freezeMembership(provenByExecutionTarget),
       retainedByExecutionTarget = _freezeMembership(retainedByExecutionTarget),
       issues = List.unmodifiable(List.from(issues));

  /// The graph capture has its own schema, currently v1.
  final int version;
  final String toolSha;
  final String projectGitSha;
  final String configSha256;
  final String packageConfigSha256;
  final String packageName;
  final String projectRoot;
  final List<OracleTarget> configuredTargets;
  final List<OracleAuxiliaryExecutionTarget> auxiliaryExecutionTargets;
  final List<String> auxiliaryExecutionTargetIssues;
  final bool membershipAvailable;
  final List<ScannerGraphNodeObservation> nodes;
  final Map<String, Set<String>> provenByExecutionTarget;
  final Map<String, Set<String>> retainedByExecutionTarget;
  final List<String> issues;

  /// Raw SHA-256 when constructed through the UTF-8 loader.
  final String? rawSha256;

  /// Validates this observation against one selected frozen scan artifact.
  void validateForArtifact({
    required AccuracyProjectManifest manifest,
    required String scanKey,
    required String expectedPackageName,
  }) {
    final scan = manifest.scans[scanKey];
    if (scan == null) throw FormatException('unknown frozen scan $scanKey');
    if (version !=
            AccuracyProjectManifest.supportedGraphObservationSchemaVersion ||
        version != scan.graphObservation.schemaVersion) {
      throw const FormatException('unsupported graph observation schema');
    }
    if (issues.isNotEmpty) {
      throw const FormatException(
        'accepted graph observation must not contain issues',
      );
    }
    if (rawSha256 == null ||
        rawSha256 != scan.graphObservation.rawObservationSha256) {
      throw const FormatException(
        'graph observation SHA-256 differs from frozen artifact',
      );
    }
    if (toolSha != manifest.toolSha ||
        projectGitSha != manifest.projectGitSha ||
        configSha256 != manifest.configSha256 ||
        packageConfigSha256 != manifest.packageConfigSha256 ||
        projectRoot != manifest.projectRoot ||
        packageName != expectedPackageName) {
      throw const FormatException(
        'graph observation identity differs from manifest',
      );
    }
    final expectedAuxiliaryIssues =
        scan.graphMembershipMode == ScannerGraphMembershipMode.notApplicable
        ? const <String>[]
        : manifest.expectedCoverage.auxiliaryExecutionTargetIssues
              .map((issue) => issue.id)
              .toList(growable: false);
    if (!_sameTargets(configuredTargets, manifest.targets) ||
        !_sameAuxiliaries(
          auxiliaryExecutionTargets,
          scan.expectedAuxiliaryExecutionTargets,
        ) ||
        !_sameStringLists(
          auxiliaryExecutionTargetIssues,
          expectedAuxiliaryIssues,
        )) {
      throw const FormatException(
        'graph observation target registry differs from selected scan',
      );
    }
    final expectedContexts = scan.expectedGraphMembershipContextIds.toSet();
    if (scan.graphMembershipMode == ScannerGraphMembershipMode.notApplicable) {
      if (membershipAvailable ||
          auxiliaryExecutionTargets.isNotEmpty ||
          provenByExecutionTarget.isNotEmpty ||
          retainedByExecutionTarget.isNotEmpty ||
          expectedContexts.isNotEmpty) {
        throw const FormatException(
          'notApplicable scan must contain no graph membership',
        );
      }
      return;
    }
    if (!membershipAvailable ||
        provenByExecutionTarget.keys.toSet().length !=
            expectedContexts.length ||
        !provenByExecutionTarget.keys.toSet().containsAll(expectedContexts) ||
        retainedByExecutionTarget.keys.toSet().length !=
            expectedContexts.length ||
        !retainedByExecutionTarget.keys.toSet().containsAll(expectedContexts)) {
      throw const FormatException(
        'graph membership contexts differ from selected scan',
      );
    }
  }
}

final class _ScannerGraphReader {
  _ScannerGraphReader(this.value, {this.rawSha256});

  final Map<String, Object?> value;
  final String? rawSha256;

  ScannerGraphObservation parse() {
    final reader = _ObjectReader(value, 'graphObservation');
    if (reader.integer('version') !=
        AccuracyProjectManifest.supportedGraphObservationSchemaVersion) {
      throw const FormatException(
        'only graph observation schema v1 is accepted',
      );
    }
    final identity = _ObjectReader(
      reader.map('identity'),
      'graphObservation.identity',
    );
    final toolSha = identity.string('toolSha');
    final projectGitSha = identity.string('projectGitSha');
    final configSha256 = identity.sha('configSha256');
    final packageConfigSha256 = identity.sha('packageConfigSha256');
    final packageName = identity.string('packageName');
    final projectRoot = identity.string('projectRoot');
    final targets = reader
        .list('configuredTargets')
        .map((value) => _target(value, 'configured target'))
        .toList(growable: false);
    _unique(
      targets.map((target) => target.executionContextId),
      'configured execution context',
    );
    final auxiliaries = reader
        .list('auxiliaryExecutionTargets')
        .map((value) => _auxiliary(value, targets))
        .toList(growable: false);
    _unique(auxiliaries.map((target) => target.id), 'auxiliary target');
    final nodes = reader
        .list('nodes')
        .map((value) {
          final item = _ObjectReader(_map(value, 'graph node'), 'graph node');
          final node = ScannerGraphNodeObservation(
            id: item.string('id'),
            kind: item.string('kind'),
            projectRelativeOrigin: item.string('projectRelativeOrigin'),
          );
          item.finish();
          return node;
        })
        .toList(growable: false);
    _unique(nodes.map((node) => node.id), 'graph node ID');
    final nodeIds = nodes.map((node) => node.id).toSet();
    final membershipAvailable = reader.boolean('membershipAvailable');
    final proven = _membership(
      reader.map('provenByExecutionTarget'),
      nodeIds,
      'proven',
    );
    final retained = _membership(
      reader.map('retainedByExecutionTarget'),
      nodeIds,
      'retained',
    );
    if (proven.keys.toSet().length != retained.keys.length ||
        !proven.keys.toSet().containsAll(retained.keys)) {
      throw const FormatException(
        'proven and retained membership contexts must agree',
      );
    }
    for (final context in proven.keys) {
      if (!retained[context]!.containsAll(proven[context]!)) {
        throw FormatException(
          'proven membership must be retained for $context',
        );
      }
    }
    final issues = reader.strings('issues');
    if (issues.isNotEmpty) {
      throw const FormatException('graph observation issues must be empty');
    }
    final auxiliaryIssues = reader.strings('auxiliaryExecutionTargetIssues');
    _unique(auxiliaryIssues, 'auxiliary execution target issue');
    reader.finish();
    identity.finish();
    if (!membershipAvailable && (proven.isNotEmpty || retained.isNotEmpty)) {
      throw const FormatException('unavailable membership must be empty');
    }
    return ScannerGraphObservation._(
      version: AccuracyProjectManifest.supportedGraphObservationSchemaVersion,
      toolSha: toolSha,
      projectGitSha: projectGitSha,
      configSha256: configSha256,
      packageConfigSha256: packageConfigSha256,
      packageName: packageName,
      projectRoot: projectRoot,
      configuredTargets: targets,
      auxiliaryExecutionTargets: auxiliaries,
      auxiliaryExecutionTargetIssues: auxiliaryIssues,
      membershipAvailable: membershipAvailable,
      nodes: nodes,
      provenByExecutionTarget: proven,
      retainedByExecutionTarget: retained,
      issues: issues,
      rawSha256: rawSha256,
    );
  }
}

Map<String, Set<String>> _membership(
  Map<String, Object?> values,
  Set<String> nodes,
  String field,
) {
  final result = <String, Set<String>>{};
  for (final entry in values.entries) {
    if (!_context(entry.key)) {
      throw FormatException('$field has noncanonical context ${entry.key}');
    }
    final ids = _list(
      entry.value,
      '$field.${entry.key}',
    ).map((value) => _string(value, '$field ID')).toSet();
    if (ids.length != _list(entry.value, '$field.${entry.key}').length ||
        !nodes.containsAll(ids)) {
      throw FormatException('$field references duplicate or unknown node');
    }
    result[entry.key] = Set.unmodifiable(ids);
  }
  return Map.unmodifiable(result);
}

OracleTarget _target(Object? value, String context) {
  final reader = _ObjectReader(_map(value, context), context);
  final defines = reader
      .map('dartDefines')
      .map(
        (key, value) =>
            MapEntry(key, _string(value, '$context.dartDefines.$key')),
      );
  final flavor = reader.optional('flavor');
  if (flavor != null && flavor is! String) {
    throw FormatException('$context.flavor must be string or null');
  }
  final target = OracleTarget(
    name: reader.string('name'),
    platform: reader.string('platform'),
    entrypoint: reader.string('entrypoint'),
    flavor: flavor as String?,
    dartDefines: defines,
  );
  try {
    target.executionContextId;
  } on StateError {
    throw FormatException('$context.name is not canonical');
  }
  if (!isCanonicalProjectRelativePosixPath(target.entrypoint)) {
    throw FormatException('$context.entrypoint is not project relative');
  }
  reader.finish();
  return target;
}

OracleAuxiliaryExecutionTarget _auxiliary(
  Object? value,
  List<OracleTarget> targets,
) {
  final reader = _ObjectReader(
    _map(value, 'auxiliary target'),
    'auxiliary target',
  );
  final domain = switch (reader.string('domain')) {
    'test' => OracleAuxiliaryDomain.test,
    'runtime' => OracleAuxiliaryDomain.runtime,
    'external' => OracleAuxiliaryDomain.external,
    _ => throw const FormatException('unknown auxiliary domain'),
  };
  final sourceValue = reader.optional('sourceConfiguredTarget');
  final source = sourceValue == null
      ? null
      : _target(sourceValue, 'auxiliary source target');
  if (source != null && !targets.any((target) => _sameTarget(target, source))) {
    throw const FormatException('unknown auxiliary source configured target');
  }
  final wireId = reader.string('id');
  String logicalId;
  try {
    logicalId = logicalAuxiliaryIdFromWire(wireId, domain);
  } on ArgumentError {
    throw const FormatException('invalid auxiliary target');
  }
  final auxiliary = OracleAuxiliaryExecutionTarget(
    id: logicalId,
    domain: domain,
    environmentValues: reader
        .map('environmentValues')
        .map(
          (key, value) =>
              MapEntry(key, _string(value, 'auxiliary environment')),
        ),
    environmentComplete: reader.boolean('environmentComplete'),
    reason: reader.string('reason'),
    sourceConfiguredTarget: source,
  );
  try {
    if (auxiliary.executionContextId != wireId) {
      throw StateError('auxiliary wire ID did not round-trip');
    }
  } on StateError {
    throw const FormatException('invalid auxiliary target');
  }
  reader.finish();
  return auxiliary;
}

bool _sameTargets(List<OracleTarget> left, List<OracleTarget> right) =>
    left.length == right.length &&
    left.indexed.every((entry) => _sameTarget(entry.$2, right[entry.$1]));

bool _sameTarget(OracleTarget left, OracleTarget right) =>
    left.executionContextId == right.executionContextId &&
    left.platform == right.platform &&
    left.entrypoint == right.entrypoint &&
    left.flavor == right.flavor &&
    _sameStrings(left.dartDefines, right.dartDefines);

bool _sameAuxiliaries(
  List<OracleAuxiliaryExecutionTarget> left,
  List<OracleAuxiliaryExecutionTarget> right,
) =>
    left.length == right.length &&
    left.indexed.every((entry) {
      final a = entry.$2;
      final b = right[entry.$1];
      return a.id == b.id &&
          a.domain == b.domain &&
          a.environmentComplete == b.environmentComplete &&
          a.reason == b.reason &&
          _sameStrings(a.environmentValues, b.environmentValues) &&
          ((a.sourceConfiguredTarget == null &&
                  b.sourceConfiguredTarget == null) ||
              (a.sourceConfiguredTarget != null &&
                  b.sourceConfiguredTarget != null &&
                  _sameTarget(
                    a.sourceConfiguredTarget!,
                    b.sourceConfiguredTarget!,
                  )));
    });

bool _sameStrings(Map<String, String> left, Map<String, String> right) =>
    left.length == right.length &&
    left.entries.every((entry) => right[entry.key] == entry.value);

bool _sameStringLists(List<String> left, List<String> right) =>
    left.length == right.length &&
    left.indexed.every((entry) => entry.$2 == right[entry.$1]);

Map<String, Set<String>> _freezeMembership(Map<String, Set<String>> value) =>
    Map.unmodifiable(
      value.map(
        (key, nodes) =>
            MapEntry(key, Set<String>.unmodifiable(Set<String>.from(nodes))),
      ),
    );

bool _context(String value) => isCanonicalExecutionTargetId(value);

void _unique(Iterable<String> values, String field) {
  final list = values.toList(growable: false);
  if (list.any((value) => value.isEmpty) ||
      list.toSet().length != list.length) {
    throw FormatException('duplicate or empty $field');
  }
}

Map<String, Object?> _map(Object? value, String context) {
  if (value is! Map) throw FormatException('$context must be an object');
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    if (entry.key is! String) {
      throw FormatException('$context has non-string key');
    }
    result[entry.key as String] = entry.value;
  }
  return result;
}

List<Object?> _list(Object? value, String context) {
  if (value is! List) throw FormatException('$context must be an array');
  return List<Object?>.from(value);
}

String _string(Object? value, String context) {
  if (value is! String || value.isEmpty) {
    throw FormatException('$context must be a non-empty string');
  }
  return value;
}

final class _ObjectReader {
  _ObjectReader(this.value, this.context);
  final Map<String, Object?> value;
  final String context;
  final Set<String> _used = <String>{};
  bool wasPresent(String key) => value.containsKey(key);
  Object? required(String key) {
    _used.add(key);
    if (!value.containsKey(key) || value[key] == null) {
      throw FormatException('$context.$key is required');
    }
    return value[key];
  }

  Object? optional(String key) {
    if (value.containsKey(key)) _used.add(key);
    return value[key];
  }

  String string(String key) => _string(required(key), '$context.$key');
  int integer(String key) {
    final result = required(key);
    if (result is! int) throw FormatException('$context.$key must be integer');
    return result;
  }

  String sha(String key) {
    final result = string(key);
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(result)) {
      throw FormatException('$context.$key must be SHA-256');
    }
    return result;
  }

  bool boolean(String key) {
    final result = required(key);
    if (result is! bool) throw FormatException('$context.$key must be boolean');
    return result;
  }

  Map<String, Object?> map(String key) => _map(required(key), '$context.$key');
  List<Object?> list(String key) => _list(required(key), '$context.$key');
  List<String> strings(String key) => list(key)
      .map((value) => _string(value, '$context.$key item'))
      .toList(growable: false);
  void finish() {
    final unknown = value.keys.toSet().difference(_used);
    if (unknown.isNotEmpty) {
      throw FormatException(
        '$context has unknown fields: ${unknown.join(',')}',
      );
    }
  }
}

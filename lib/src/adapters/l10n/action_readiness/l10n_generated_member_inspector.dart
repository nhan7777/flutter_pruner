import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/nullability_suffix.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/error/error.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../../core/project/project_context.dart';
import '../../dart/dart_analysis_workspace.dart';
import '../arb_inventory.dart';
import 'l10n_evidence_failure.dart';
import 'l10n_generation_config.dart';

const _stage = 'generated-member-inspection';

/// Analyzer-resolved generated member evidence for one configured l10n output.
final class L10nGeneratedMemberInspection {
  /// Creates a deeply immutable, deterministically ordered inspection.
  L10nGeneratedMemberInspection({
    required Map<String, ArbGeneratedMemberKind> membersByMessageKey,
    required Map<String, String> memberIdentitiesByMessageKey,
    required Iterable<L10nEvidenceFailure> failures,
    required this.lookupIdentity,
    required this.identity,
  }) : membersByMessageKey = Map<String, ArbGeneratedMemberKind>.unmodifiable(
         SplayTreeMap<String, ArbGeneratedMemberKind>.of(membersByMessageKey),
       ),
       memberIdentitiesByMessageKey = Map<String, String>.unmodifiable(
         SplayTreeMap<String, String>.of(memberIdentitiesByMessageKey),
       ),
       failures = _sortedFailures(failures) {
    if (!_isSha256(identity)) {
      throw ArgumentError.value(identity, 'identity');
    }
    if (lookupIdentity != null && !_isSha256(lookupIdentity!)) {
      throw ArgumentError.value(lookupIdentity, 'lookupIdentity');
    }
    if (this.memberIdentitiesByMessageKey.keys.toSet().length !=
            this.membersByMessageKey.keys.toSet().length ||
        !this.memberIdentitiesByMessageKey.keys.toSet().containsAll(
          this.membersByMessageKey.keys,
        ) ||
        this.memberIdentitiesByMessageKey.values.any(
          (value) => !_isSha256(value),
        )) {
      throw ArgumentError('Member identity keys and values are invalid.');
    }
  }

  /// Actual generated getter/method kind for each requested frozen message key.
  final Map<String, ArbGeneratedMemberKind> membersByMessageKey;

  /// Exact resolved signature identity for every observed message member.
  final Map<String, String> memberIdentitiesByMessageKey;

  /// Exact resolved signature identity for the configured static `of` lookup.
  final String? lookupIdentity;

  /// Stable fail-closed inspection failures.
  final List<L10nEvidenceFailure> failures;

  /// Root-independent SHA-256 of config, expectations, observations, and errors.
  final String identity;
}

/// Analyzer-backed inspector for the exact configured generated Dart library.
final class L10nGeneratedMemberInspector {
  /// Creates the stateless production inspector.
  const L10nGeneratedMemberInspector();

  /// Inspects actual resolved member shapes for the frozen message-key set.
  Future<L10nGeneratedMemberInspection> inspect({
    required ProjectContext stagedProject,
    required L10nGenerationConfig config,
    required Map<String, ArbGeneratedMemberKind> expectedMemberKindsByKey,
  }) async {
    final expected = SplayTreeMap<String, ArbGeneratedMemberKind>.of(
      expectedMemberKindsByKey,
    );
    final relativePath = config.baseOutputPath;
    final observations = SplayTreeMap<String, _MemberObservation>();
    final failures = <L10nEvidenceFailure>[];
    String? lookupIdentity;

    L10nGeneratedMemberInspection finish() => _finish(
      config: config,
      relativePath: relativePath,
      expected: expected,
      observations: observations,
      lookupIdentity: lookupIdentity,
      failures: failures,
    );

    final outputPath = p.normalize(stagedProject.resolve(relativePath));
    if (!_isExactProjectPath(stagedProject, outputPath, relativePath)) {
      failures.add(_failure('generated-library-path-invalid', relativePath));
      return finish();
    }
    final outputType = FileSystemEntity.typeSync(
      outputPath,
      followLinks: false,
    );
    if (outputType == FileSystemEntityType.notFound) {
      failures.add(_failure('generated-library-missing', relativePath));
      return finish();
    }
    if (outputType != FileSystemEntityType.file) {
      failures.add(_failure('generated-library-not-regular', relativePath));
      return finish();
    }

    try {
      final source = await File(outputPath).readAsString();
      final parsed = parseString(
        content: source,
        path: outputPath,
        featureSet: stagedProject.dartFeatureSet,
        throwIfDiagnostics: false,
      );
      if (parsed.errors.any(
        (error) => error.diagnosticCode.severity == DiagnosticSeverity.ERROR,
      )) {
        failures.add(_failure('generated-library-parse-failed', relativePath));
        return finish();
      }
    } on FileSystemException {
      failures.add(_failure('generated-library-parse-failed', relativePath));
      return finish();
    } on FormatException {
      failures.add(_failure('generated-library-parse-failed', relativePath));
      return finish();
    } catch (_) {
      failures.add(_failure('generated-library-parse-failed', relativePath));
      return finish();
    }

    final SomeResolvedLibraryResult resolved;
    try {
      resolved = await DartAnalysisWorkspace(
        stagedProject,
      ).resolveLibrary(outputPath);
    } catch (_) {
      failures.add(
        _failure('generated-library-resolution-failed', relativePath),
      );
      return finish();
    }
    if (resolved is! ResolvedLibraryResult) {
      failures.add(
        _failure('generated-library-resolution-failed', relativePath),
      );
      return finish();
    }

    final classes = resolved.element.classes
        .where((element) => element.name == config.outputClass)
        .toList(growable: false);
    if (classes.isEmpty) {
      failures.add(_failure('configured-output-class-missing', relativePath));
      return finish();
    }
    if (classes.length != 1) {
      failures.add(_failure('configured-output-class-ambiguous', relativePath));
      return finish();
    }

    final outputClass = classes.single;
    if (!_isDeclaredInFile(outputClass, outputPath)) {
      failures.add(
        _failure('configured-output-class-path-mismatch', relativePath),
      );
      return finish();
    }
    final lookup = _inspectLookup(
      outputClass,
      stagedProject: stagedProject,
      nullableGetter: config.nullableGetter,
      relativePath: relativePath,
      outputPath: outputPath,
    );
    lookupIdentity = lookup.identity;
    if (lookup.failure != null) failures.add(lookup.failure!);

    for (final key in expected.keys) {
      final getters = outputClass.getters
          .where((member) => member.name == key)
          .toList(growable: false);
      final methods = outputClass.methods
          .where((member) => member.name == key)
          .toList(growable: false);
      if (getters.length + methods.length > 1) {
        failures.add(_failure('generated-member-ambiguous', relativePath));
        continue;
      }
      final ExecutableElement? member =
          getters.firstOrNull ?? methods.firstOrNull;
      if (member == null) continue;
      if (member.isStatic ||
          member.typeParameters.isNotEmpty ||
          !_isNonNullableDartCoreString(member.returnType) ||
          member.library != resolved.element ||
          !_isDeclaredInFile(member, outputPath)) {
        failures.add(_failure('generated-member-shape-invalid', relativePath));
        continue;
      }
      final kind = member is GetterElement
          ? ArbGeneratedMemberKind.getter
          : ArbGeneratedMemberKind.method;
      observations[key] = _MemberObservation(
        kind: kind,
        signature: _memberSignature(member, stagedProject: stagedProject),
      );
    }

    if (failures.isEmpty &&
        resolved.units.any(
          (unit) => unit.diagnostics.any(
            (diagnostic) =>
                diagnostic.diagnosticCode.severity == DiagnosticSeverity.ERROR,
          ),
        )) {
      observations.clear();
      failures.add(
        _failure('generated-library-resolution-failed', relativePath),
      );
    }
    if (failures.isNotEmpty) {
      observations.clear();
      lookupIdentity = null;
    }
    return finish();
  }
}

({L10nEvidenceFailure? failure, String? identity}) _inspectLookup(
  InterfaceElement outputClass, {
  required ProjectContext stagedProject,
  required bool nullableGetter,
  required String relativePath,
  required String outputPath,
}) {
  final methods = outputClass.methods
      .where((member) => member.name == 'of')
      .toList(growable: false);
  final getters = outputClass.getters
      .where((member) => member.name == 'of')
      .toList(growable: false);
  if (methods.isEmpty && getters.isEmpty) {
    return (
      failure: _failure('generated-lookup-missing', relativePath),
      identity: null,
    );
  }
  if (methods.length != 1 || getters.isNotEmpty) {
    return (
      failure: _failure('generated-lookup-ambiguous', relativePath),
      identity: null,
    );
  }
  final method = methods.single;
  final parameters = method.formalParameters;
  final returnType = method.returnType;
  if (!method.isStatic ||
      method.typeParameters.isNotEmpty ||
      !_isDeclaredInFile(method, outputPath) ||
      parameters.length != 1 ||
      !parameters.single.isRequiredPositional ||
      !_isBuildContext(parameters.single.type) ||
      returnType is! InterfaceType ||
      returnType.element != outputClass) {
    return (
      failure: _failure('generated-lookup-shape-mismatch', relativePath),
      identity: null,
    );
  }
  final actualNullable =
      returnType.nullabilitySuffix == NullabilitySuffix.question;
  if (returnType.nullabilitySuffix == NullabilitySuffix.star ||
      actualNullable != nullableGetter) {
    return (
      failure: _failure('generated-lookup-nullability-mismatch', relativePath),
      identity: null,
    );
  }
  return (
    failure: null,
    identity: _memberSignature(method, stagedProject: stagedProject),
  );
}

bool _isBuildContext(DartType type) =>
    type is InterfaceType &&
    type.nullabilitySuffix == NullabilitySuffix.none &&
    type.element.name == 'BuildContext';

bool _isNonNullableDartCoreString(DartType type) {
  if (type is! InterfaceType ||
      type.nullabilitySuffix != NullabilitySuffix.none ||
      type.element.name != 'String') {
    return false;
  }
  return type.element.library.firstFragment.source.uri.toString() ==
      'dart:core';
}

L10nGeneratedMemberInspection _finish({
  required L10nGenerationConfig config,
  required String relativePath,
  required SplayTreeMap<String, ArbGeneratedMemberKind> expected,
  required SplayTreeMap<String, _MemberObservation> observations,
  required String? lookupIdentity,
  required Iterable<L10nEvidenceFailure> failures,
}) {
  final sortedFailures = _sortedFailures(failures);
  final frames = <String>[
    'l10n-generated-member-inspection-v1',
    config.configurationIdentity,
    relativePath,
    config.outputClass,
    config.nullableGetter ? 'nullable-lookup' : 'non-nullable-lookup',
    'lookup',
    lookupIdentity ?? 'unavailable',
    for (final entry in expected.entries) ...[
      'expected',
      entry.key,
      entry.value.name,
    ],
    for (final entry in observations.entries) ...[
      'observed',
      entry.key,
      entry.value.kind.name,
      entry.value.signature,
    ],
    for (final failure in sortedFailures) ...[
      'failure',
      failure.code.name,
      failure.stage,
      failure.detailCode,
      failure.relativePath ?? '',
    ],
  ];
  return L10nGeneratedMemberInspection(
    membersByMessageKey: {
      for (final entry in observations.entries) entry.key: entry.value.kind,
    },
    memberIdentitiesByMessageKey: {
      for (final entry in observations.entries)
        entry.key: entry.value.signature,
    },
    failures: sortedFailures,
    lookupIdentity: lookupIdentity,
    identity: _hashFrames(frames),
  );
}

String _memberSignature(
  ExecutableElement member, {
  required ProjectContext stagedProject,
}) {
  final frames = <String>[
    member is GetterElement ? 'getter' : 'method',
    member.name ?? '',
    member.isStatic ? 'static' : 'instance',
    member.isAbstract ? 'abstract' : 'concrete',
    member.isExternal ? 'external' : 'internal',
    _typeIdentity(member.returnType, stagedProject),
    for (final parameter in member.typeParameters) ...[
      'type-parameter',
      parameter.name ?? '',
      parameter.bound == null
          ? 'unbounded'
          : _typeIdentity(parameter.bound!, stagedProject),
    ],
    for (final parameter in member.formalParameters) ...[
      'parameter',
      _parameterKind(parameter),
      parameter.name ?? '',
      parameter.isCovariant ? 'covariant' : 'invariant',
      _typeIdentity(parameter.type, stagedProject),
      parameter.defaultValueCode ?? '',
    ],
  ];
  return _hashFrames(frames);
}

String _typeIdentity(
  DartType type,
  ProjectContext project, [
  Set<DartType>? activeTypes,
]) {
  final active = activeTypes ?? HashSet<DartType>.identity();
  if (!active.add(type)) {
    return _hashFrames([
      'recursive-type',
      type.element?.displayName ?? type.runtimeType.toString(),
      type.nullabilitySuffix.name,
    ]);
  }
  try {
    return _typeIdentityUnchecked(type, project, active);
  } finally {
    active.remove(type);
  }
}

String _typeIdentityUnchecked(
  DartType type,
  ProjectContext project,
  Set<DartType> activeTypes,
) {
  final nullability = type.nullabilitySuffix.name;
  final alias = type.alias;
  final aliasIdentity = alias == null
      ? ''
      : _hashFrames([
          'alias',
          _elementIdentity(alias.element, project),
          alias.nullabilitySuffix.name,
          for (final argument in alias.typeArguments)
            _typeIdentity(argument, project, activeTypes),
        ]);
  final body = switch (type) {
    DynamicType() => 'dynamic',
    VoidType() => 'void',
    NeverType() => 'never',
    InvalidType() => 'invalid',
    InterfaceType() => _hashFrames([
      'interface',
      _elementIdentity(type.element, project),
      for (final argument in type.typeArguments)
        _typeIdentity(argument, project, activeTypes),
    ]),
    TypeParameterType() => _hashFrames([
      'type-parameter',
      type.element.name ?? '',
      _typeIdentity(type.bound, project, activeTypes),
    ]),
    FunctionType() => _hashFrames([
      'function',
      _typeIdentity(type.returnType, project, activeTypes),
      for (final parameter in type.typeParameters) ...[
        parameter.name ?? '',
        parameter.bound == null
            ? 'unbounded'
            : _typeIdentity(parameter.bound!, project, activeTypes),
      ],
      for (final parameter in type.formalParameters) ...[
        _parameterKind(parameter),
        parameter.name ?? '',
        _typeIdentity(parameter.type, project, activeTypes),
      ],
    ]),
    RecordType() => _hashFrames([
      'record',
      for (final field in type.positionalFields)
        _typeIdentity(field.type, project, activeTypes),
      for (final field in type.namedFields) ...[
        field.name,
        _typeIdentity(field.type, project, activeTypes),
      ],
    ]),
    _ => _hashFrames([
      'other',
      type.runtimeType.toString(),
      if (type.element != null) _elementIdentity(type.element!, project),
    ]),
  };
  return _hashFrames(['type', body, nullability, aliasIdentity]);
}

String _elementIdentity(Element element, ProjectContext project) {
  final library = element.library;
  final source = library?.firstFragment.source;
  if (source == null) return 'no-library:${element.displayName}';
  final fullName = p.normalize(p.absolute(source.fullName));
  final root = p.normalize(p.absolute(project.root.path));
  final String libraryIdentity;
  if (p.equals(fullName, root) || p.isWithin(root, fullName)) {
    libraryIdentity =
        'project:${p.relative(fullName, from: root).replaceAll(r'\', '/')}';
  } else if (source.uri.scheme == 'dart' || source.uri.scheme == 'package') {
    libraryIdentity = source.uri.toString();
  } else {
    libraryIdentity =
        'external:${p.basename(fullName)}:${_fileContentIdentity(fullName)}';
  }
  return '$libraryIdentity#${element.displayName}';
}

String _fileContentIdentity(String path) {
  try {
    if (FileSystemEntity.typeSync(path, followLinks: false) !=
        FileSystemEntityType.file) {
      return 'unavailable';
    }
    return sha256.convert(File(path).readAsBytesSync()).toString();
  } on FileSystemException {
    return 'unavailable';
  }
}

String _parameterKind(FormalParameterElement parameter) {
  if (parameter.isRequiredNamed) return 'required-named';
  if (parameter.isOptionalNamed) return 'optional-named';
  if (parameter.isOptionalPositional) return 'optional-positional';
  return 'required-positional';
}

bool _isExactProjectPath(
  ProjectContext project,
  String absolutePath,
  String relativePath,
) {
  final root = p.normalize(p.absolute(project.root.path));
  final resolved = p.normalize(p.absolute(absolutePath));
  if (!p.isWithin(root, resolved)) return false;
  return project.relative(resolved) == relativePath;
}

bool _isDeclaredInFile(Element element, String outputPath) {
  final sourcePath = element.firstFragment.libraryFragment?.source.fullName;
  return sourcePath != null &&
      p.equals(
        p.normalize(p.absolute(sourcePath)),
        p.normalize(p.absolute(outputPath)),
      );
}

L10nEvidenceFailure _failure(String detailCode, String relativePath) =>
    L10nEvidenceFailure(
      code: L10nEvidenceRejectionCode.candidateVerificationFailed,
      stage: _stage,
      detailCode: detailCode,
      relativePath: relativePath,
    );

List<L10nEvidenceFailure> _sortedFailures(
  Iterable<L10nEvidenceFailure> source,
) {
  final sorted = List<L10nEvidenceFailure>.of(source)..sort(_compareFailures);
  final result = <L10nEvidenceFailure>[];
  for (final failure in sorted) {
    if (result.isEmpty || _compareFailures(result.last, failure) != 0) {
      result.add(failure);
    }
  }
  return List<L10nEvidenceFailure>.unmodifiable(result);
}

int _compareFailures(L10nEvidenceFailure left, L10nEvidenceFailure right) {
  var comparison = left.code.index.compareTo(right.code.index);
  if (comparison != 0) return comparison;
  comparison = left.stage.compareTo(right.stage);
  if (comparison != 0) return comparison;
  comparison = _compareNullable(left.relativePath, right.relativePath);
  if (comparison != 0) return comparison;
  return left.detailCode.compareTo(right.detailCode);
}

int _compareNullable(String? left, String? right) {
  if (left == null) return right == null ? 0 : -1;
  if (right == null) return 1;
  return left.compareTo(right);
}

String _hashFrames(Iterable<String> values) {
  final bytes = BytesBuilder(copy: false);
  for (final value in values) {
    final encoded = utf8.encode(value);
    bytes
      ..add(utf8.encode(encoded.length.toString()))
      ..addByte(0)
      ..add(encoded)
      ..addByte(0xff);
  }
  return sha256.convert(bytes.takeBytes()).toString();
}

bool _isSha256(String value) => RegExp(r'^[0-9a-f]{64}$').hasMatch(value);

final class _MemberObservation {
  const _MemberObservation({required this.kind, required this.signature});

  final ArbGeneratedMemberKind kind;
  final String signature;
}

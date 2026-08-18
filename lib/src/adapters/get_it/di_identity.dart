import 'dart:convert';

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/nullability_suffix.dart';
import 'package:analyzer/dart/element/type.dart';

/// A resolved type identity suitable for exact GetIt matching.
///
/// The value is derived only from analyzer semantic data. It deliberately does
/// not use `getDisplayString()`, whose content is intended for presentation.
final class DiTypeKey {
  const DiTypeKey._(this.value);

  /// Collision-free canonical representation of the resolved type.
  final String value;

  @override
  bool operator ==(Object other) => other is DiTypeKey && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// Returns an exact key for a canonical resolved interface type.
///
/// Types without a stable library URI, such as dynamic, invalid, type
/// parameters, and file-backed libraries, return `null`. Callers must treat
/// that result as uncertainty rather than inventing an identity.
DiTypeKey? diTypeKey(DartType type) {
  if (type is! InterfaceType) return null;
  return _interfaceTypeKey(type);
}

DiTypeKey? _interfaceTypeKey(InterfaceType type) {
  final libraryUri = type.element.library.uri;
  if (!_isStableLibraryUri(libraryUri)) return null;
  final elementName = type.element.name;
  if (elementName == null) return null;

  final arguments = <DiTypeKey>[];
  for (final argument in type.typeArguments) {
    final key = diTypeKey(argument);
    if (key == null) return null;
    arguments.add(key);
  }

  final fields = <String>[
    _encoded(libraryUri.toString()),
    _encoded(elementName),
    _nullabilityToken(type.nullabilitySuffix),
    '${arguments.length}',
    ...arguments.map((argument) => _encoded(argument.value)),
  ];
  return DiTypeKey._('interface|${fields.join('|')}');
}

bool _isStableLibraryUri(Uri uri) =>
    uri.isAbsolute && uri.scheme != 'file' && uri.scheme.isNotEmpty;

String _nullabilityToken(NullabilitySuffix suffix) => switch (suffix) {
  NullabilitySuffix.none => 'nonNullable',
  NullabilitySuffix.question => 'nullable',
  NullabilitySuffix.star => 'legacy',
};

/// The state of a GetIt `instanceName:` argument.
sealed class DiInstanceName {
  const DiInstanceName();

  String get _identity;

  @override
  bool operator ==(Object other) =>
      other is DiInstanceName && other._identity == _identity;

  @override
  int get hashCode => _identity.hashCode;
}

/// No `instanceName:` argument was supplied.
final class DiAbsentInstanceName extends DiInstanceName {
  /// Creates the absent `instanceName:` state.
  const DiAbsentInstanceName();

  @override
  String get _identity => 'absent';
}

/// An `instanceName:` argument that is a compile-time constant string.
final class DiConstantInstanceName extends DiInstanceName {
  /// Creates a constant-string `instanceName:` state.
  const DiConstantInstanceName(this.value);

  /// The exact constant string supplied to GetIt.
  final String value;

  @override
  String get _identity => 'constant|${_encoded(value)}';
}

/// An `instanceName:` argument was supplied but is not a constant string.
final class DiDynamicInstanceName extends DiInstanceName {
  /// Creates the dynamic `instanceName:` state.
  const DiDynamicInstanceName();

  @override
  String get _identity => 'dynamic';
}

/// Classifies an `instanceName:` expression without conflating dynamic and
/// unnamed lookups.
DiInstanceName diInstanceName(Expression? expression) {
  if (expression == null) return const DiAbsentInstanceName();

  final literal = _constantString(expression);
  return literal == null
      ? const DiDynamicInstanceName()
      : DiConstantInstanceName(literal);
}

String? _constantString(Expression expression) {
  if (expression is StringLiteral) return expression.stringValue;
  final element = switch (expression) {
    SimpleIdentifier(:final element) => element,
    PrefixedIdentifier(:final identifier) => identifier.element,
    PropertyAccess(:final propertyName) => propertyName.element,
    _ => null,
  };
  final variable = switch (element) {
    PropertyAccessorElement(:final variable) => variable,
    VariableElement() => element,
    _ => null,
  };
  try {
    return variable?.computeConstantValue()?.toStringValue();
  } on StateError {
    return null;
  }
}

/// Exact `(type, instanceName)` key for a GetIt registration or lookup.
final class DiLookupKey {
  /// Creates an exact GetIt lookup key.
  DiLookupKey({required this.type, required this.instanceName}) {
    if (instanceName is DiDynamicInstanceName) {
      throw ArgumentError.value(
        instanceName,
        'instanceName',
        'a dynamic instanceName does not identify an exact GetIt lookup',
      );
    }
  }

  /// The canonical requested service type.
  final DiTypeKey type;

  /// The three-state instance-name identity.
  final DiInstanceName instanceName;

  /// Collision-free graph id for this lookup within [package].
  String graphId({required String package}) =>
      'di:lookup|${_encoded(package)}|${_encoded(type.value)}|'
      '${_encoded(instanceName._identity)}';

  @override
  bool operator ==(Object other) =>
      other is DiLookupKey &&
      other.type == type &&
      other.instanceName == instanceName;

  @override
  int get hashCode => Object.hash(type, instanceName);
}

/// The state of a GetIt scope argument.
sealed class DiScopeIdentity {
  const DiScopeIdentity();

  String get _identity;

  @override
  bool operator ==(Object other) =>
      other is DiScopeIdentity && other._identity == _identity;

  @override
  int get hashCode => _identity.hashCode;
}

/// The default GetIt container scope.
final class DiBaseScope extends DiScopeIdentity {
  /// Creates the default scope identity.
  const DiBaseScope();

  @override
  String get _identity => 'base';
}

/// A compile-time constant named GetIt scope.
final class DiNamedScope extends DiScopeIdentity {
  /// Creates a named scope identity.
  const DiNamedScope(this.value);

  /// The exact constant name supplied for the scope.
  final String value;

  @override
  String get _identity => 'named|${_encoded(value)}';
}

/// A scope argument that was supplied but cannot be resolved statically.
final class DiDynamicScope extends DiScopeIdentity {
  /// Creates the dynamic scope identity.
  const DiDynamicScope();

  @override
  String get _identity => 'dynamic';
}

/// One portable source location within the analyzed project.
final class DiSourceOccurrence {
  /// Creates a stable project-relative source occurrence.
  factory DiSourceOccurrence({required String path, required int offset}) {
    if (offset < 0) {
      throw ArgumentError.value(offset, 'offset', 'must be non-negative');
    }
    return DiSourceOccurrence._(
      path: _normalizeProjectRelativePath(path),
      offset: offset,
    );
  }

  const DiSourceOccurrence._({required this.path, required this.offset});

  /// Normalized slash-separated path relative to the package root.
  final String path;

  /// Zero-based source offset within [path].
  final int offset;

  String get _identity => '$path@$offset';

  @override
  bool operator ==(Object other) =>
      other is DiSourceOccurrence &&
      other.path == path &&
      other.offset == offset;

  @override
  int get hashCode => Object.hash(path, offset);
}

String _normalizeProjectRelativePath(String path) {
  final normalized = path.replaceAll('\\', '/');
  final isUri = RegExp(r'^[A-Za-z][A-Za-z0-9+.-]*:').hasMatch(normalized);
  final segments = normalized.split('/');
  if (normalized.isEmpty ||
      normalized.startsWith('/') ||
      isUri ||
      segments.any(
        (segment) => segment.isEmpty || segment == '.' || segment == '..',
      )) {
    throw ArgumentError.value(
      path,
      'path',
      'must be a non-empty project-relative path without traversal',
    );
  }
  return normalized;
}

/// One source registration occurrence, distinct from the lookup it provides.
final class DiRegistrationOccurrence {
  /// Creates one registration source occurrence with an exact lookup key.
  ///
  /// [source] must identify a portable source occurrence within the package.
  factory DiRegistrationOccurrence({
    required String package,
    required DiLookupKey lookup,
    required DiSourceOccurrence source,
    DiScopeIdentity scope = const DiBaseScope(),
    Iterable<String> environments = const [],
  }) => DiRegistrationOccurrence._(
    package: package,
    type: lookup.type,
    instanceName: lookup.instanceName,
    lookup: lookup,
    source: source,
    scope: scope,
    environments: environments,
  );

  /// Creates a unique blocked occurrence for a dynamic `instanceName:`.
  ///
  /// This cannot be used as an exact lookup key, but keeps the declaration
  /// available for fail-closed reporting and scoped blockers.
  factory DiRegistrationOccurrence.withDynamicInstanceName({
    required String package,
    required DiTypeKey type,
    required DiSourceOccurrence source,
    DiScopeIdentity scope = const DiBaseScope(),
    Iterable<String> environments = const [],
  }) => DiRegistrationOccurrence._(
    package: package,
    type: type,
    instanceName: const DiDynamicInstanceName(),
    source: source,
    scope: scope,
    environments: environments,
  );

  DiRegistrationOccurrence._({
    required this.package,
    required this.type,
    required this.instanceName,
    required this.source,
    required this.scope,
    required Iterable<String> environments,
    this.lookup,
  }) : environments = List.unmodifiable(environments.toSet().toList()..sort());

  /// Package whose GetIt container owns this registration.
  final String package;

  /// The semantic service type, including for blocked dynamic-name entries.
  final DiTypeKey type;

  /// The declared instance-name state for this registration.
  final DiInstanceName instanceName;

  /// Exact service key this registration provides.
  ///
  /// This is `null` for a dynamic-name registration occurrence.
  final DiLookupKey? lookup;

  /// Stable package-relative source occurrence for this registration.
  final DiSourceOccurrence source;

  /// The default, named, or dynamic scope identity.
  final DiScopeIdentity scope;

  /// Stable, sorted environment names declared for this registration.
  final List<String> environments;

  /// Collision-free graph id that retains duplicate registration occurrences.
  String get graphId =>
      '${diRegistrationNamespace(package: package)}${_encoded(type.value)}|'
      '${_encoded(instanceName._identity)}|${_encoded(scope._identity)}|'
      '${environments.length}|${environments.map(_encoded).join('|')}|'
      '${_encoded(source._identity)}';
}

/// Collision-safe namespace covering every registration in [package].
///
/// This is the exact prefix of [DiRegistrationOccurrence.graphId], so a
/// namespace blocker covers every registration in that package.
String diRegistrationNamespace({required String package}) =>
    'di:registration|${_encoded(package)}|';

/// Escapes arbitrary data into a delimiter-free, reversible component.
String _encoded(String value) => base64UrlEncode(utf8.encode(value));

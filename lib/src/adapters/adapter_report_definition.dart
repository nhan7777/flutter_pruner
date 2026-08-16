import '../core/graph/node.dart';

/// Presentation metadata an adapter contributes to structured reports.
///
/// This catalog describes labels and typed metadata only. It must not carry
/// confidence, action, or safety-policy decisions.
final class AdapterReportDefinition {
  /// Creates a report-definition catalog for one adapter.
  AdapterReportDefinition({
    required this.adapterId,
    required this.displayName,
    this.description = '',
    List<AdapterFindingReportDefinition> findings = const [],
    List<AdapterReportMeasurementDefinition> measurements = const [],
  }) : findings = List.unmodifiable(
         findings.map((finding) => finding.snapshot()),
       ),
       measurements = List.unmodifiable(measurements);

  /// Stable id of the adapter that owns this catalog.
  final String adapterId;

  /// Human-readable adapter name shown to users.
  final String displayName;

  /// Optional explanatory copy for the adapter's report section.
  final String description;

  /// Finding presentations supported by this adapter.
  final List<AdapterFindingReportDefinition> findings;

  /// Measurements produced by this adapter.
  final List<AdapterReportMeasurementDefinition> measurements;

  /// Returns the presentation for [nodeKind], if this adapter reports it.
  AdapterFindingReportDefinition? findingFor(NodeKind nodeKind) {
    for (final finding in findings) {
      if (finding.nodeKind == nodeKind) return finding;
    }
    return null;
  }

  /// Returns the presentation for measurement [kind], if it is known.
  AdapterReportMeasurementDefinition? measurementFor(String kind) {
    for (final measurement in measurements) {
      if (measurement.kind == kind) return measurement;
    }
    return null;
  }

  /// Returns a deeply immutable snapshot suitable for a long-lived run report.
  AdapterReportDefinition snapshot() => AdapterReportDefinition(
    adapterId: adapterId,
    displayName: displayName,
    description: description,
    findings: findings,
    measurements: measurements,
  );

  /// Validates this catalog against its owning adapter identity.
  ///
  /// The registry calls this before filtering adapters so invalid presentation
  /// metadata cannot be hidden by an `--only` selection.
  void validate({String? adapterId, String? displayName}) {
    final ownerAdapterId = adapterId ?? this.adapterId;
    final ownerDisplayName = displayName ?? this.displayName;
    if (this.adapterId != ownerAdapterId) {
      throw StateError(
        'Report definition adapter id "${this.adapterId}" does not match '
        'adapter "$ownerAdapterId".',
      );
    }
    if (this.displayName != ownerDisplayName) {
      throw StateError(
        'Report definition display name "${this.displayName}" does not '
        'match adapter "$ownerAdapterId" name "$ownerDisplayName".',
      );
    }

    _validateAdapterId(this.adapterId);
    _validateRequiredText(this.displayName, 'display name', ownerAdapterId);
    _validateOptionalText(description, 'description', ownerAdapterId);

    for (final finding in findings) {
      _validateRuleId(finding.ruleId, ownerAdapterId);
      _validateRequiredText(finding.title, 'finding title', ownerAdapterId);
      _validateRequiredText(
        finding.nodeLabel,
        'finding node label',
        ownerAdapterId,
      );
      _validateOptionalText(
        finding.description,
        'finding description',
        ownerAdapterId,
      );
      for (final detail in finding.details) {
        _validateDetailKey(detail.key, ownerAdapterId);
        _validateRequiredText(detail.label, 'detail label', ownerAdapterId);
        _validateOptionalText(
          detail.description,
          'detail description',
          ownerAdapterId,
        );
      }
    }
    for (final measurement in measurements) {
      _validateMeasurementKind(measurement.kind, ownerAdapterId);
      _validateRequiredText(
        measurement.label,
        'measurement label',
        ownerAdapterId,
      );
      _validateRequiredText(
        measurement.unit,
        'measurement unit',
        ownerAdapterId,
      );
      _validateOptionalText(
        measurement.description,
        'measurement description',
        ownerAdapterId,
      );
    }

    _validateUnique(
      findings.map((finding) => finding.nodeKind),
      'node kind',
      ownerAdapterId,
    );
    _validateUnique(
      findings.map((finding) => finding.ruleId),
      'rule id',
      ownerAdapterId,
    );
    _validateUnique(
      measurements.map((measurement) => measurement.kind),
      'measurement kind',
      ownerAdapterId,
    );
    for (final finding in findings) {
      _validateUnique(
        finding.details.map((detail) => detail.key),
        'detail key for ${finding.nodeKind.name}',
        ownerAdapterId,
      );
    }

    for (final finding in findings) {
      final measurementKind = finding.measurementKind;
      if (measurementKind != null && measurementFor(measurementKind) == null) {
        throw StateError(
          'Report definition for adapter "$ownerAdapterId" references unknown '
          'measurement kind "$measurementKind".',
        );
      }
    }
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is AdapterReportDefinition &&
            adapterId == other.adapterId &&
            displayName == other.displayName &&
            description == other.description &&
            _listEquals(findings, other.findings) &&
            _listEquals(measurements, other.measurements);
  }

  @override
  int get hashCode => Object.hash(
    adapterId,
    displayName,
    description,
    Object.hashAll(findings),
    Object.hashAll(measurements),
  );
}

/// Presentation metadata for one reported node kind and rule.
final class AdapterFindingReportDefinition {
  /// Creates presentation metadata for one finding kind.
  AdapterFindingReportDefinition({
    required this.nodeKind,
    required this.ruleId,
    required this.title,
    required this.nodeLabel,
    this.description = '',
    this.measurementKind,
    List<AdapterReportDetailDefinition> details = const [],
  }) : details = List.unmodifiable(details);

  /// Graph node kind this definition renders.
  final NodeKind nodeKind;

  /// Stable rule id emitted for this node kind.
  final String ruleId;

  /// User-facing finding title, without the node-specific name.
  final String title;

  /// User-facing label for the reported node.
  final String nodeLabel;

  /// Optional explanatory copy for this finding presentation.
  final String description;

  /// Related adapter-scoped measurement kind, when one exists.
  final String? measurementKind;

  /// Typed node metadata to include in the presentation.
  final List<AdapterReportDetailDefinition> details;

  /// Returns an immutable copy of this finding presentation.
  AdapterFindingReportDefinition snapshot() => AdapterFindingReportDefinition(
    nodeKind: nodeKind,
    ruleId: ruleId,
    title: title,
    nodeLabel: nodeLabel,
    description: description,
    measurementKind: measurementKind,
    details: details,
  );

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is AdapterFindingReportDefinition &&
            nodeKind == other.nodeKind &&
            ruleId == other.ruleId &&
            title == other.title &&
            nodeLabel == other.nodeLabel &&
            description == other.description &&
            measurementKind == other.measurementKind &&
            _listEquals(details, other.details);
  }

  @override
  int get hashCode => Object.hash(
    nodeKind,
    ruleId,
    title,
    nodeLabel,
    description,
    measurementKind,
    Object.hashAll(details),
  );
}

/// Typed presentation metadata for one adapter-owned node metadata key.
final class AdapterReportDetailDefinition {
  /// Creates a typed metadata presentation definition.
  const AdapterReportDetailDefinition({
    required this.key,
    required this.label,
    required this.valueType,
    this.description = '',
  });

  /// Metadata key on the graph node.
  final String key;

  /// User-facing metadata label.
  final String label;

  /// Expected metadata value type.
  final AdapterReportDetailValueType valueType;

  /// Optional explanatory copy for this metadata value.
  final String description;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is AdapterReportDetailDefinition &&
            key == other.key &&
            label == other.label &&
            valueType == other.valueType &&
            description == other.description;
  }

  @override
  int get hashCode => Object.hash(key, label, valueType, description);
}

/// Supported value types for presentation metadata.
enum AdapterReportDetailValueType {
  /// Plain text.
  text,

  /// A count or other integer value.
  integer,

  /// A true-or-false value.
  boolean,

  /// A byte count.
  bytes,

  /// One filesystem path.
  path,

  /// A list of filesystem paths.
  paths,
}

/// Presentation metadata for one adapter-scoped run measurement.
final class AdapterReportMeasurementDefinition {
  /// Creates a measurement presentation definition.
  const AdapterReportMeasurementDefinition({
    required this.kind,
    required this.label,
    required this.unit,
    this.description = '',
  });

  /// Stable measurement identifier.
  final String kind;

  /// User-facing measurement label.
  final String label;

  /// Unit emitted with the measurement.
  final String unit;

  /// Optional explanatory copy for this measurement.
  final String description;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is AdapterReportMeasurementDefinition &&
            kind == other.kind &&
            label == other.label &&
            unit == other.unit &&
            description == other.description;
  }

  @override
  int get hashCode => Object.hash(kind, label, unit, description);
}

void _validateUnique<T>(Iterable<T> values, String label, String adapterId) {
  final seen = <T>{};
  for (final value in values) {
    if (!seen.add(value)) {
      throw StateError(
        'Report definition for adapter "$adapterId" has duplicate $label '
        '"$value".',
      );
    }
  }
}

void _validateAdapterId(String adapterId) {
  if (!_adapterIdPattern.hasMatch(adapterId)) {
    throw StateError(
      'Report definition adapter id "$adapterId" must be lowercase snake_case.',
    );
  }
}

void _validateRuleId(String ruleId, String adapterId) {
  if (ruleId.startsWith('PRN-UNKNOWN-') || !_ruleIdPattern.hasMatch(ruleId)) {
    throw StateError(
      'Report definition for adapter "$adapterId" has invalid rule id '
      '"$ruleId".',
    );
  }
}

void _validateMeasurementKind(String kind, String adapterId) {
  if (!_measurementKindPattern.hasMatch(kind)) {
    throw StateError(
      'Report definition for adapter "$adapterId" has measurement kind '
      '"$kind" that is not lowercase kebab-case.',
    );
  }
}

void _validateDetailKey(String key, String adapterId) {
  if (!_detailKeyPattern.hasMatch(key)) {
    throw StateError(
      'Report definition for adapter "$adapterId" has detail key "$key" '
      'that is not lowerCamelCase.',
    );
  }
}

void _validateRequiredText(String value, String label, String adapterId) {
  if (value.isEmpty || value != value.trim()) {
    throw StateError(
      'Report definition for adapter "$adapterId" has $label that must be '
      'non-empty and trimmed.',
    );
  }
}

void _validateOptionalText(String value, String label, String adapterId) {
  if (value.isNotEmpty && value != value.trim()) {
    throw StateError(
      'Report definition for adapter "$adapterId" has $label that must be '
      'trimmed when present.',
    );
  }
}

final RegExp _adapterIdPattern = RegExp(r'^[a-z][a-z0-9]*(?:_[a-z0-9]+)*$');
final RegExp _ruleIdPattern = RegExp(r'^PRN-[A-Z0-9]+-[0-9]{3}$');
final RegExp _measurementKindPattern = RegExp(
  r'^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$',
);
final RegExp _detailKeyPattern = RegExp(r'^[a-z][A-Za-z0-9]*$');

bool _listEquals<T>(List<T> left, List<T> right) {
  if (identical(left, right)) return true;
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

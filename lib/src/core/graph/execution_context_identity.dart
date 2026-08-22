import 'execution_target.dart' show AuxiliaryExecutionDomain;

const _configuredPrefix = 'app:';
const _auxiliaryPrefix = 'aux:';

/// Derives the canonical graph/report identity for a configured target name.
String configuredExecutionContextId(String rawTargetName) {
  final id = rawTargetName.startsWith(_configuredPrefix)
      ? rawTargetName
      : '$_configuredPrefix$rawTargetName';
  final suffix = id.substring(_configuredPrefix.length);
  if (!_isValidSuffix(suffix)) {
    throw ArgumentError.value(
      rawTargetName,
      'rawTargetName',
      'Configured execution-context names must derive a nonempty '
          'control-free app:<id> identity.',
    );
  }
  return id;
}

/// Validates one canonical auxiliary graph/report identity.
void validateAuxiliaryExecutionContextId(
  String id,
  AuxiliaryExecutionDomain domain,
) {
  final prefix = '$_auxiliaryPrefix${domain.name}:';
  final suffix = id.startsWith(prefix) ? id.substring(prefix.length) : '';
  if (!_isValidSuffix(suffix) ||
      suffix.startsWith(_configuredPrefix) ||
      suffix.startsWith(_auxiliaryPrefix)) {
    throw ArgumentError.value(
      id,
      'id',
      'Auxiliary execution target IDs must use a canonical '
          '$prefix<id> form with a non-nested, control-free suffix.',
    );
  }
}

/// Returns the JSON integrity domain for one canonical context identity.
String executionContextDomain(String id, {bool allowUnattributed = false}) {
  if (allowUnattributed && id == 'unattributed') return 'unattributed';
  if (id.startsWith(_configuredPrefix)) {
    if (configuredExecutionContextId(id) != id) {
      throw ArgumentError.value(id, 'id', 'Non-canonical configured context.');
    }
    return 'configuredTarget';
  }
  for (final domain in AuxiliaryExecutionDomain.values) {
    final prefix = '$_auxiliaryPrefix${domain.name}:';
    if (!id.startsWith(prefix)) continue;
    validateAuxiliaryExecutionContextId(id, domain);
    return 'auxiliary';
  }
  throw ArgumentError.value(id, 'id', 'Unknown execution-context identity.');
}

bool _isValidSuffix(String value) =>
    value.isNotEmpty &&
    !value.codeUnits.any((unit) => unit <= 0x1f || unit == 0x7f);

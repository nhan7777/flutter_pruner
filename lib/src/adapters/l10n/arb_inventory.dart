import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/project/project_context.dart';
import 'l10n_config.dart';

/// Flutter gen-l10n validates filename suffixes against this ISO language set.
const Set<String> _flutterLanguageCodes = {
  'aa',
  'ab',
  'ae',
  'af',
  'ak',
  'am',
  'an',
  'ar',
  'as',
  'av',
  'ay',
  'az',
  'ba',
  'be',
  'bg',
  'bh',
  'bi',
  'bm',
  'bn',
  'bo',
  'br',
  'bs',
  'ca',
  'ce',
  'ch',
  'co',
  'cr',
  'cs',
  'cu',
  'cv',
  'cy',
  'da',
  'de',
  'dv',
  'dz',
  'ee',
  'el',
  'en',
  'eo',
  'es',
  'et',
  'eu',
  'fa',
  'ff',
  'fi',
  'fil',
  'fj',
  'fo',
  'fr',
  'fy',
  'ga',
  'gd',
  'gl',
  'gn',
  'gsw',
  'gu',
  'gv',
  'ha',
  'he',
  'hi',
  'ho',
  'hr',
  'ht',
  'hu',
  'hy',
  'hz',
  'ia',
  'id',
  'ie',
  'ig',
  'ii',
  'ik',
  'io',
  'is',
  'it',
  'iu',
  'ja',
  'jv',
  'ka',
  'kg',
  'ki',
  'kj',
  'kk',
  'kl',
  'km',
  'kn',
  'ko',
  'kr',
  'ks',
  'ku',
  'kv',
  'kw',
  'ky',
  'la',
  'lb',
  'lg',
  'li',
  'ln',
  'lo',
  'lt',
  'lu',
  'lv',
  'mg',
  'mh',
  'mi',
  'mk',
  'ml',
  'mn',
  'mr',
  'ms',
  'mt',
  'my',
  'na',
  'nb',
  'nd',
  'ne',
  'ng',
  'nl',
  'nn',
  'no',
  'nr',
  'nv',
  'ny',
  'oc',
  'oj',
  'om',
  'or',
  'os',
  'pa',
  'pi',
  'pl',
  'ps',
  'pt',
  'qu',
  'rm',
  'rn',
  'ro',
  'ru',
  'rw',
  'sa',
  'sc',
  'sd',
  'se',
  'sg',
  'si',
  'sk',
  'sl',
  'sm',
  'sn',
  'so',
  'sq',
  'sr',
  'ss',
  'st',
  'su',
  'sv',
  'sw',
  'ta',
  'te',
  'tg',
  'th',
  'ti',
  'tk',
  'tl',
  'tn',
  'to',
  'tr',
  'ts',
  'tt',
  'tw',
  'ty',
  'ug',
  'uk',
  'ur',
  'uz',
  've',
  'vi',
  'vo',
  'wa',
  'wo',
  'xh',
  'yi',
  'yo',
  'za',
  'zh',
  'zu',
};

/// The generated member shape implied by an ARB message.
enum ArbGeneratedMemberKind {
  /// A parameter-free generated getter.
  getter,

  /// A generated method accepting placeholders or an ICU selector.
  method,
}

/// A message declared by the configured template ARB file.
final class ArbKey {
  /// Creates an immutable template-message inventory entry.
  ArbKey({
    required this.key,
    required this.nodeId,
    required this.origin,
    required this.location,
    required this.memberKind,
    required this.missingLocales,
  });

  /// ARB message key.
  final String key;

  /// Collision-safe logical localization node id.
  final String nodeId;

  /// Template ARB file declaring this message.
  final Uri origin;

  /// Project-relative declaration location.
  final String location;

  /// Whether Flutter generates a getter or parameterized method.
  final ArbGeneratedMemberKind memberKind;

  /// Stable, comma-separated locale codes that omit this message.
  final String missingLocales;

  /// Whether the generated member accepts placeholders.
  bool get hasPlaceholders => memberKind == ArbGeneratedMemberKind.method;
}

/// A bounded ARB uncertainty that callers must turn into a graph blocker.
final class ArbBlocker {
  /// Creates a scoped ARB blocker record.
  ArbBlocker({
    required this.reason,
    this.location,
    this.affectedNamespace,
    this.affectedNodeIds = const {},
  }) : assert(affectedNamespace != null || affectedNodeIds.isNotEmpty);

  /// Why the ARB input could not be modeled safely.
  final String reason;

  /// Project-relative input location where known.
  final String? location;

  /// Namespace bounded by this uncertainty.
  final String? affectedNamespace;

  /// Exact template message nodes bounded by this uncertainty.
  final Set<String> affectedNodeIds;
}

/// Deterministic, fail-closed inventory of configured ARB messages.
final class ArbInventory {
  ArbInventory._({
    required List<ArbKey> keys,
    required List<ArbBlocker> blockers,
  }) : keys = List<ArbKey>.unmodifiable(keys),
       blockers = List<ArbBlocker>.unmodifiable(blockers);

  /// Template messages in lexical key order.
  final List<ArbKey> keys;

  /// Input uncertainties in stable location/reason order.
  final List<ArbBlocker> blockers;

  /// Namespace covering every localization key in [project].
  static String namespaceFor(ProjectContext project) =>
      'l10n:${Uri.encodeComponent(project.packageName)}:';

  /// Reads the configured ARB files without letting malformed input escape.
  static ArbInventory read(ProjectContext project, L10nConfig config) {
    final blockers = <ArbBlocker>[];
    final namespace = namespaceFor(project);
    final arbDirectory = Directory(config.arbDir);
    final templateLocation = project.relative(config.templateArbPath);

    final arbFiles = <File>[];
    try {
      if (FileSystemEntity.typeSync(arbDirectory.path) !=
          FileSystemEntityType.directory) {
        blockers.add(
          ArbBlocker(
            reason:
                'configured ARB directory does not exist or is not a directory',
            location: project.relative(arbDirectory.path),
            affectedNamespace: namespace,
          ),
        );
        return _result(const [], blockers);
      }
      final rootPath = project.root.resolveSymbolicLinksSync();
      final candidates =
          arbDirectory
              .listSync(followLinks: false)
              .where(
                (entity) => p.extension(entity.path).toLowerCase() == '.arb',
              )
              .toList()
            ..sort((left, right) => left.path.compareTo(right.path));
      for (final candidate in candidates) {
        final location = project.relative(candidate.path);
        if (FileSystemEntity.typeSync(candidate.path, followLinks: false) !=
            FileSystemEntityType.file) {
          blockers.add(
            ArbBlocker(
              reason: 'ARB candidate is not a regular file',
              location: location,
              affectedNamespace: namespace,
            ),
          );
          continue;
        }
        final canonicalPath = File(candidate.path).resolveSymbolicLinksSync();
        if (!_isWithin(rootPath, canonicalPath)) {
          blockers.add(
            ArbBlocker(
              reason: 'ARB candidate resolves outside the project',
              location: location,
              affectedNamespace: namespace,
            ),
          );
          continue;
        }
        arbFiles.add(File(canonicalPath));
      }
      arbFiles.sort((left, right) => left.path.compareTo(right.path));
    } on FileSystemException {
      blockers.add(
        ArbBlocker(
          reason: 'configured ARB directory could not be enumerated',
          location: project.relative(arbDirectory.path),
          affectedNamespace: namespace,
        ),
      );
      return _result(const [], blockers);
    }

    final templateFile = File(config.templateArbPath);
    final template = _readDocument(templateFile);
    if (template is _DocumentFailure) {
      blockers.add(
        ArbBlocker(
          reason: template.reason,
          location: templateLocation,
          affectedNamespace: namespace,
        ),
      );
      return _result(const [], blockers);
    }
    final templateDocument = template as _ArbDocument;
    final templateLocale = _localeFor(templateFile, templateDocument.locale);
    if (templateLocale.reason != null) {
      blockers.add(
        ArbBlocker(
          reason: templateLocale.reason!,
          location: templateLocation,
          affectedNamespace: namespace,
        ),
      );
    }

    final invalidTemplateKeys = templateDocument.issues
        .map((issue) => issue.key)
        .whereType<String>()
        .toSet();
    final keys = <ArbKey>[];
    final keysByName = <String, ArbKey>{};
    final orderedTemplateKeys = templateDocument.messages.keys.toList()..sort();
    for (final key in orderedTemplateKeys) {
      if (invalidTemplateKeys.contains(key)) {
        continue;
      }
      final entry = ArbKey(
        key: key,
        nodeId: '$namespace${Uri.encodeComponent(key)}',
        origin: templateFile.uri,
        location: templateLocation,
        memberKind: _memberKind(
          templateDocument.messages[key]!,
          templateDocument.metadata[key],
        ),
        missingLocales: '',
      );
      keys.add(entry);
      keysByName[key] = entry;
    }
    _appendIssues(
      blockers,
      templateDocument.issues,
      location: templateLocation,
      keysByName: keysByName,
      namespace: namespace,
    );
    _appendTemplateMetadataConsistency(
      blockers,
      templateDocument,
      keysByName,
      templateLocation,
    );

    final locales = <String, _ArbDocument>{};
    for (final file in arbFiles) {
      if (p.equals(p.normalize(file.path), p.normalize(templateFile.path))) {
        continue;
      }
      final location = project.relative(file.path);
      final parsed = _readDocument(file);
      if (parsed is _DocumentFailure) {
        blockers.add(
          ArbBlocker(
            reason: parsed.reason,
            location: location,
            affectedNamespace: namespace,
          ),
        );
        continue;
      }
      final document = parsed as _ArbDocument;
      _appendIssues(
        blockers,
        document.issues,
        location: location,
        keysByName: keysByName,
        namespace: namespace,
      );
      if (document.issues.isNotEmpty) continue;

      final localeResult = _localeFor(file, document.locale);
      if (localeResult.reason != null) {
        blockers.add(
          ArbBlocker(
            reason: localeResult.reason!,
            location: location,
            affectedNamespace: namespace,
          ),
        );
        continue;
      }
      final locale = localeResult.locale!;
      if (locales.containsKey(locale)) {
        blockers.add(
          ArbBlocker(
            reason: 'multiple ARB files declare locale $locale',
            location: location,
            affectedNamespace: namespace,
          ),
        );
        continue;
      }
      locales[locale] = document;

      for (final name in document.messages.keys) {
        if (keysByName.containsKey(name)) continue;
        blockers.add(
          ArbBlocker(
            reason: 'locale-only message key $name cannot extend the template',
            location: location,
            affectedNamespace: namespace,
          ),
        );
      }
      _appendInconsistentMetadata(
        blockers,
        document,
        templateDocument,
        keysByName,
        location,
        namespace,
      );
    }

    final sortedLocales = locales.keys.toList()..sort();
    final completedKeys = <ArbKey>[
      for (final key in keys)
        ArbKey(
          key: key.key,
          nodeId: key.nodeId,
          origin: key.origin,
          location: key.location,
          memberKind: key.memberKind,
          missingLocales: [
            for (final locale in sortedLocales)
              if (!locales[locale]!.messages.containsKey(key.key)) locale,
          ].join(','),
        ),
    ];
    return _result(completedKeys, blockers);
  }

  static ArbInventory _result(List<ArbKey> keys, List<ArbBlocker> blockers) {
    blockers.sort((left, right) {
      final location = (left.location ?? '').compareTo(right.location ?? '');
      if (location != 0) return location;
      final reason = left.reason.compareTo(right.reason);
      if (reason != 0) return reason;
      return left.affectedNodeIds
          .join(',')
          .compareTo(right.affectedNodeIds.join(','));
    });
    return ArbInventory._(keys: keys, blockers: blockers);
  }
}

ArbGeneratedMemberKind _memberKind(
  String message,
  Map<String, Object?>? metadata,
) {
  final placeholders = metadata?['placeholders'];
  if (placeholders is Map && placeholders.isNotEmpty) {
    return ArbGeneratedMemberKind.method;
  }
  if (RegExp(r'\{\s*[A-Za-z_]\w*\s*(?:\}|,)').hasMatch(message)) {
    return ArbGeneratedMemberKind.method;
  }
  return ArbGeneratedMemberKind.getter;
}

void _appendIssues(
  List<ArbBlocker> blockers,
  Iterable<_ArbIssue> issues, {
  required String location,
  required Map<String, ArbKey> keysByName,
  required String namespace,
}) {
  for (final issue in issues) {
    final key = issue.key == null ? null : keysByName[issue.key];
    blockers.add(
      ArbBlocker(
        reason: issue.reason,
        location: location,
        affectedNamespace: key == null ? namespace : null,
        affectedNodeIds: key == null ? const {} : {key.nodeId},
      ),
    );
  }
}

void _appendInconsistentMetadata(
  List<ArbBlocker> blockers,
  _ArbDocument locale,
  _ArbDocument template,
  Map<String, ArbKey> keysByName,
  String location,
  String namespace,
) {
  for (final entry in locale.messages.entries) {
    final key = keysByName[entry.key];
    final templateMessage = template.messages[entry.key];
    if (key == null || templateMessage == null) continue;
    final expectedNames = _messagePlaceholderNames(templateMessage);
    if (!_sameStrings(_messagePlaceholderNames(entry.value), expectedNames)) {
      blockers.add(
        ArbBlocker(
          reason:
              'locale placeholders for ${entry.key} differ from the template',
          location: location,
          affectedNodeIds: {key.nodeId},
        ),
      );
    }
  }
  for (final entry in locale.metadata.entries) {
    final templateMetadata = template.metadata[entry.key];
    final key = keysByName[entry.key];
    if (key == null || templateMetadata == null) {
      blockers.add(
        ArbBlocker(
          reason:
              'locale metadata for ${entry.key} is inconsistent with the template',
          location: location,
          affectedNamespace: key == null ? namespace : null,
          affectedNodeIds: key == null ? const {} : {key.nodeId},
        ),
      );
      continue;
    }
    final localeNames = _placeholderNames(entry.value);
    final templateNames = _placeholderNames(templateMetadata);
    if (!_sameStrings(localeNames, templateNames)) {
      blockers.add(
        ArbBlocker(
          reason:
              'locale placeholders for ${entry.key} differ from the template',
          location: location,
          affectedNodeIds: {key.nodeId},
        ),
      );
    }
  }
}

void _appendTemplateMetadataConsistency(
  List<ArbBlocker> blockers,
  _ArbDocument template,
  Map<String, ArbKey> keysByName,
  String location,
) {
  for (final entry in template.metadata.entries) {
    final key = keysByName[entry.key];
    final message = template.messages[entry.key];
    if (key == null || message == null) continue;
    if (!_sameStrings(
      _placeholderNames(entry.value),
      _messagePlaceholderNames(message),
    )) {
      blockers.add(
        ArbBlocker(
          reason:
              'template placeholders for ${entry.key} differ from its metadata',
          location: location,
          affectedNodeIds: {key.nodeId},
        ),
      );
    }
  }
}

Set<String> _placeholderNames(Map<String, Object?> metadata) {
  final placeholders = metadata['placeholders'];
  if (placeholders is! Map) {
    return const {};
  }
  return placeholders.keys.whereType<String>().toSet();
}

Set<String> _messagePlaceholderNames(String message) => RegExp(
  r'\{\s*([A-Za-z_]\w*)\s*(?:\}|,)',
).allMatches(message).map((match) => match.group(1)!).toSet();

bool _sameStrings(Set<String> left, Set<String> right) =>
    left.length == right.length && left.containsAll(right);

_LocaleResult _localeFor(File file, String? declaredLocale) {
  final base = p.basenameWithoutExtension(file.path);
  final filenameLocale = _filenameLocale(base);
  if (declaredLocale != null) {
    if (filenameLocale == null || filenameLocale == declaredLocale) {
      return _LocaleResult.value(declaredLocale);
    }
    return _LocaleResult.error(
      'ARB filename locale $filenameLocale differs from @@locale $declaredLocale',
    );
  }
  if (filenameLocale != null) {
    return _LocaleResult.value(filenameLocale);
  }
  return const _LocaleResult.error(
    'ARB filename locale could not be determined safely',
  );
}

String? _filenameLocale(String basename) {
  final wholeBasename = _normalizeFilenameLocale(basename);
  if (wholeBasename != null) return wholeBasename;
  for (final separator in RegExp('_').allMatches(basename)) {
    final normalized = _normalizeFilenameLocale(
      basename.substring(separator.end),
    );
    if (normalized != null) return normalized;
  }
  return null;
}

String? _normalizeFilenameLocale(String value) {
  final normalized = _normalizeLocaleSyntax(value);
  if (normalized == null) return null;
  final language = normalized.split('_').first;
  return _flutterLanguageCodes.contains(language) ? normalized : null;
}

String? _normalizeLocaleSyntax(String value) {
  final segments = value.split(RegExp('[-_]'));
  if (segments.isEmpty || segments.length > 3) return null;
  final language = segments.first.toLowerCase();
  if (!RegExp(r'^[a-z]{2,3}$').hasMatch(language)) {
    return null;
  }
  String? script;
  String? region;
  if (segments.length >= 2) {
    final second = segments[1];
    if (RegExp(r'^[A-Za-z]{4}$').hasMatch(second)) {
      script = '${second[0].toUpperCase()}${second.substring(1).toLowerCase()}';
    } else if (RegExp(r'^[A-Za-z]{2}$').hasMatch(second)) {
      region = second.toUpperCase();
    } else if (RegExp(r'^\d{3}$').hasMatch(second)) {
      region = second;
    } else {
      return null;
    }
  }
  if (segments.length == 3) {
    if (script == null) return null;
    final third = segments[2];
    if (RegExp(r'^[A-Za-z]{2}$').hasMatch(third)) {
      region = third.toUpperCase();
    } else if (RegExp(r'^\d{3}$').hasMatch(third)) {
      region = third;
    } else {
      return null;
    }
  }
  return [
    language,
    if (script != null) script,
    if (region != null) region,
  ].join('_');
}

bool _isWithin(String root, String candidate) =>
    p.equals(root, candidate) || p.isWithin(root, candidate);

final class _LocaleResult {
  const _LocaleResult.value(this.locale) : reason = null;

  const _LocaleResult.error(this.reason) : locale = null;

  final String? locale;
  final String? reason;
}

sealed class _ReadResult {}

final class _DocumentFailure extends _ReadResult {
  _DocumentFailure(this.reason);

  final String reason;
}

final class _ArbDocument extends _ReadResult {
  _ArbDocument({
    required this.messages,
    required this.metadata,
    required this.locale,
    required this.issues,
  });

  final Map<String, String> messages;
  final Map<String, Map<String, Object?>> metadata;
  final String? locale;
  final List<_ArbIssue> issues;
}

final class _ArbIssue {
  const _ArbIssue(this.reason, [this.key]);

  final String reason;
  final String? key;
}

_ReadResult _readDocument(File file) {
  final String source;
  try {
    if (FileSystemEntity.typeSync(file.path) != FileSystemEntityType.file) {
      return _DocumentFailure('ARB file is missing or is not a regular file');
    }
    source = file.readAsStringSync();
  } on FileSystemException {
    return _DocumentFailure('ARB file could not be read');
  }

  final scan = _TopLevelJsonKeyScanner.scan(source);
  if (scan.error != null) {
    return _DocumentFailure(scan.error!);
  }
  if (scan.duplicateKey != null) {
    return _DocumentFailure(
      'ARB file has duplicate top-level key ${scan.duplicateKey}',
    );
  }

  final Object? decoded;
  try {
    decoded = jsonDecode(source);
  } on FormatException {
    return _DocumentFailure('ARB file contains malformed JSON');
  }
  if (decoded is! Map) {
    return _DocumentFailure('ARB top level must be a JSON object');
  }

  final values = <String, Object?>{};
  for (final entry in decoded.entries) {
    if (entry.key is! String) {
      return _DocumentFailure('ARB top-level keys must be strings');
    }
    values[entry.key as String] = entry.value;
  }
  return _inspectDocument(values);
}

_ArbDocument _inspectDocument(Map<String, Object?> values) {
  final messages = <String, String>{};
  final metadata = <String, Map<String, Object?>>{};
  final issues = <_ArbIssue>[];
  String? locale;

  for (final entry in values.entries) {
    final key = entry.key;
    final value = entry.value;
    if (key == '@@locale') {
      final normalizedLocale = value is String
          ? _normalizeLocaleSyntax(value.trim())
          : null;
      if (normalizedLocale == null) {
        issues.add(
          const _ArbIssue('@@locale must be a non-empty supported locale'),
        );
      } else {
        locale = normalizedLocale;
      }
      continue;
    }
    if (key.startsWith('@@')) continue;
    if (key.startsWith('@')) continue;
    if (value is! String) {
      issues.add(_ArbIssue('message $key must have a string value', key));
      continue;
    }
    messages[key] = value;
  }

  for (final entry in values.entries) {
    final rawKey = entry.key;
    if (!rawKey.startsWith('@') || rawKey.startsWith('@@')) continue;
    final key = rawKey.substring(1);
    final value = entry.value;
    if (key.isEmpty || value is! Map) {
      issues.add(
        _ArbIssue(
          'metadata $rawKey must be a JSON object',
          key.isEmpty ? null : key,
        ),
      );
      continue;
    }
    final normalized = <String, Object?>{};
    var valid = true;
    for (final metadataEntry in value.entries) {
      if (metadataEntry.key is! String) {
        valid = false;
        break;
      }
      normalized[metadataEntry.key as String] = metadataEntry.value;
    }
    if (!valid) {
      issues.add(_ArbIssue('metadata $rawKey must use string keys', key));
      continue;
    }
    final description = normalized['description'];
    if (description != null && description is! String) {
      issues.add(
        _ArbIssue('metadata description for $key must be a string', key),
      );
      continue;
    }
    final placeholders = normalized['placeholders'];
    if (placeholders != null) {
      if (placeholders is! Map ||
          placeholders.entries.any(
            (placeholder) =>
                placeholder.key is! String || placeholder.value is! Map,
          )) {
        issues.add(
          _ArbIssue(
            'metadata placeholders for $key must map names to objects',
            key,
          ),
        );
        continue;
      }
      if (!_validatePlaceholderAttributes(placeholders, key, issues)) {
        continue;
      }
    }
    if (!messages.containsKey(key)) {
      issues.add(_ArbIssue('metadata $rawKey has no matching message', key));
      continue;
    }
    metadata[key] = normalized;
  }
  return _ArbDocument(
    messages: messages,
    metadata: metadata,
    locale: locale,
    issues: issues,
  );
}

bool _validatePlaceholderAttributes(
  Map<Object?, Object?> placeholders,
  String messageKey,
  List<_ArbIssue> issues,
) {
  var valid = true;
  for (final entry in placeholders.entries) {
    final placeholderName = entry.key as String;
    final attributes = entry.value as Map<Object?, Object?>;
    for (final attribute in const ['example', 'type', 'format']) {
      if (!attributes.containsKey(attribute)) continue;
      final value = attributes[attribute];
      if (value is! String || value.trim().isEmpty) {
        issues.add(
          _ArbIssue(
            '$attribute for $messageKey.$placeholderName must be a non-empty string',
            messageKey,
          ),
        );
        valid = false;
      }
    }
    if (attributes.containsKey('isCustomDateFormat')) {
      final value = attributes['isCustomDateFormat'];
      if (value is! bool && value != 'true' && value != 'false') {
        issues.add(
          _ArbIssue(
            'isCustomDateFormat for $messageKey.$placeholderName must be a bool or true/false string',
            messageKey,
          ),
        );
        valid = false;
      }
    }
    if (attributes.containsKey('optionalParameters')) {
      final optionalParameters = attributes['optionalParameters'];
      if (optionalParameters is! Map) {
        issues.add(
          _ArbIssue(
            'optionalParameters for $messageKey.$placeholderName must be a JSON object',
            messageKey,
          ),
        );
        valid = false;
      } else if (_containsNullValue(optionalParameters)) {
        issues.add(
          _ArbIssue(
            'optionalParameters for $messageKey.$placeholderName must not contain null values',
            messageKey,
          ),
        );
        valid = false;
      }
    }
  }
  return valid;
}

bool _containsNullValue(Object? value) {
  if (value == null) return true;
  if (value is Map) {
    return value.entries.any(
      (entry) =>
          _containsNullValue(entry.key) || _containsNullValue(entry.value),
    );
  }
  if (value is Iterable) return value.any(_containsNullValue);
  return false;
}

final class _JsonKeyScan {
  const _JsonKeyScan({this.error, this.duplicateKey});

  final String? error;
  final String? duplicateKey;
}

/// Minimal JSON scanner that records decoded keys only for the top object.
///
/// `jsonDecode` intentionally overwrites duplicate map members, so this scan
/// runs first and follows nested values structurally rather than using regex.
final class _TopLevelJsonKeyScanner {
  _TopLevelJsonKeyScanner(this.source);

  final String source;
  int index = 0;

  static _JsonKeyScan scan(String source) {
    try {
      return _TopLevelJsonKeyScanner(source)._scan();
    } on _JsonScanException catch (error) {
      return _JsonKeyScan(error: error.message);
    }
  }

  _JsonKeyScan _scan() {
    _space();
    if (!_take('{')) {
      return const _JsonKeyScan(error: 'ARB top level must be a JSON object');
    }
    final keys = <String>{};
    _space();
    if (_take('}')) return _finished();
    while (true) {
      final key = _string();
      if (!keys.add(key)) {
        return _JsonKeyScan(duplicateKey: key);
      }
      _space();
      if (!_take(':')) {
        throw const _JsonScanException('ARB file contains malformed JSON');
      }
      _value();
      _space();
      if (_take('}')) return _finished();
      if (!_take(',')) {
        throw const _JsonScanException('ARB file contains malformed JSON');
      }
      _space();
    }
  }

  _JsonKeyScan _finished() {
    _space();
    if (index != source.length) {
      return const _JsonKeyScan(error: 'ARB file contains malformed JSON');
    }
    return const _JsonKeyScan();
  }

  void _value() {
    _space();
    if (index >= source.length) {
      throw const _JsonScanException('ARB file contains malformed JSON');
    }
    final character = source[index];
    if (character == '"') {
      _string();
      return;
    }
    if (character == '{') {
      index++;
      _space();
      if (_take('}')) return;
      while (true) {
        _string();
        _space();
        if (!_take(':')) {
          throw const _JsonScanException('ARB file contains malformed JSON');
        }
        _value();
        _space();
        if (_take('}')) return;
        if (!_take(',')) {
          throw const _JsonScanException('ARB file contains malformed JSON');
        }
        _space();
      }
    }
    if (character == '[') {
      index++;
      _space();
      if (_take(']')) return;
      while (true) {
        _value();
        _space();
        if (_take(']')) return;
        if (!_take(',')) {
          throw const _JsonScanException('ARB file contains malformed JSON');
        }
        _space();
      }
    }
    final start = index;
    while (index < source.length && !',]} \t\r\n'.contains(source[index])) {
      index++;
    }
    if (start == index) {
      throw const _JsonScanException('ARB file contains malformed JSON');
    }
  }

  String _string() {
    _space();
    if (!_take('"')) {
      throw const _JsonScanException('ARB file contains malformed JSON');
    }
    final start = index - 1;
    var escaped = false;
    while (index < source.length) {
      final character = source[index++];
      if (escaped) {
        escaped = false;
      } else if (character == '\\') {
        escaped = true;
      } else if (character == '"') {
        final token = source.substring(start, index);
        try {
          final value = jsonDecode(token);
          if (value is String) return value;
        } on FormatException {
          // The generic malformed-JSON error below is stable for callers.
        }
        throw const _JsonScanException('ARB file contains malformed JSON');
      }
    }
    throw const _JsonScanException('ARB file contains malformed JSON');
  }

  void _space() {
    while (index < source.length && ' \t\r\n'.contains(source[index])) {
      index++;
    }
  }

  bool _take(String character) {
    if (index >= source.length || source[index] != character) return false;
    index++;
    return true;
  }
}

final class _JsonScanException implements Exception {
  const _JsonScanException(this.message);

  final String message;
}

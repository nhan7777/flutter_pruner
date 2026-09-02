import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

const _oracleHashes = {
  'smooth': '3ba9fb5be7bb70dcb68856cf4339c3e80626d30844fbc93dd7c81ecf5cc99020',
  'gsy': '9e113537db5e2a7b057bffc0d1ff74ce6799c2b31b36b89ff36bcf3afda65d35',
  'gitjournal':
      'e07dafbb2b3cdecba0e928a08f0025ed8cc8bc161e0979dec73bb460b13ffc77',
};

const _negativeFixtures = {
  'scan-blocker': ['scanBlockerPresent'],
  'pseudo-key-selection': ['invalidSelection'],
  'unknown-config-option': ['unsupportedConfiguration'],
  'path-escape': ['invalidInputPath'],
  'locale-only-key': ['arbFamilyIncomplete'],
  'malformed-arb': ['arbParseFailure'],
  'stale-live-output': ['staleGeneratedOutput'],
  'candidate-output-created': ['outputFamilyAmbiguous'],
  'candidate-output-deleted': ['outputFamilyAmbiguous'],
  'unexpected-stage-write': ['unexpectedStageWrite'],
  'source-drift': ['sourceDrift'],
  'package-resolution-drift': ['packageResolutionDrift'],
  'toolchain-drift': ['toolchainDrift'],
  'cleanup-failure': ['cleanupFailed'],
};

const _smoothFullPolicyCorrections = <String>{
  'barcode_barcode',
  'category_picker_no_category_found_button',
  'category_picker_no_category_found_message',
  'dev_preferences_migration_subtitle',
  'email_body_account_deletion',
  'importance_label',
  'pct_match',
  'product_search_button_download_more',
  'product_search_no_more_results',
  'user_profile_title_id_default',
  'user_profile_title_id_email',
};

const _families = <String, _FamilySpec>{
  'smooth': _FamilySpec(
    project: 'smooth',
    revision: 'bac71afd115f72e379c0b501b95e5ede20ecd636',
    packageRoot: 'packages/smooth_app',
    arbDirectory: 'packages/smooth_app/lib/l10n',
    templateArb: 'packages/smooth_app/lib/l10n/app_en.arb',
    frameworkVersion: '3.44.9',
  ),
  'gsy': _FamilySpec(
    project: 'gsy',
    revision: '2b6c49008afc44b90fee869dedf8e59a86482953',
    packageRoot: '.',
    arbDirectory: 'lib/common/localization/l10n',
    templateArb: 'lib/common/localization/l10n/app_en.arb',
    frameworkVersion: '3.44.1',
  ),
  'gitjournal': _FamilySpec(
    project: 'gitjournal',
    revision: 'c8a67e098db06335762f822d7733c330f4bd0d6b',
    packageRoot: '.',
    arbDirectory: 'lib/l10n',
    templateArb: 'lib/l10n/app_en.arb',
    frameworkVersion: '3.41.5',
  ),
};

const _gitjournalFrameworkRevision = '2c9eb20739dfec95e2c74bd3dfa4601b0a8a36aa';
const _gitjournalEngineRevision = '052f31d115eceda8cbff1b3481fcde4330c4ae12';
const _gitjournalDartVersion = '3.11.3';
const _gitjournalCiEvidenceHash =
    '4980a6207c2caa7a0f65cbc7b1390eb1fffe18f3dad3e7bb0b072cf033dd94d3';
const _gitjournalProbeHash =
    'f1635a2a13f5ca240c48dc4fb8e0fab82758ce6aedeb66a3664af7d38844989c';
const _smoothFrameworkRevision = '6b182d2c7585eba26d4edce0f97630effd256c33';
const _smoothEngineRevision = '5a2a6a42cce67f965cf540fcecf616faca624aa1';
const _smoothDartVersion = '3.12.2';
const _publicSurfaceStagingPlaceholder = '<PUBLIC_SURFACE_STAGING_ROOT>';

Future<void> main(List<String> arguments) async {
  final options = _parseArguments(arguments);
  final evidenceRoot = _canonicalEvidenceRoot(
    Directory(options['evidence-root']!),
  );
  final corpusRoot = _retainedCorpusRoot(evidenceRoot);
  final outputDirectory = Directory(options['output-directory']!);
  final repositories = {
    'smooth': Directory(options['smooth-repository']!),
    'gsy': Directory(options['gsy-repository']!),
    'gitjournal': Directory(options['gitjournal-repository']!),
  };
  final initialRepositoryStates = <String, Uint8List>{};

  for (final entry in repositories.entries) {
    final spec = _families[entry.key]!;
    _verifyRepository(entry.value, spec.revision);
    initialRepositoryStates[entry.key] = _repositoryStatus(entry.value);
  }

  final oracleDocuments = <String, Map<String, Object?>>{};
  final sourceOracles = <String, Object?>{};
  for (final project in _families.keys) {
    final relativePath = '$project-l10n-oracle.json';
    final file = File(p.join(evidenceRoot.path, relativePath));
    final bytes = file.readAsBytesSync();
    final actualHash = _sha256(bytes);
    _require(
      actualHash == _oracleHashes[project],
      '$project oracle SHA-256 mismatch: $actualHash',
    );
    final document = _jsonObject(jsonDecode(utf8.decode(bytes)));
    _require(document['project'] == project, '$project oracle label mismatch');
    oracleDocuments[project] = document;
    sourceOracles[project] = {
      'relativePath': relativePath,
      'sha256': actualHash,
    };
  }

  final gsyNormalization = _buildGsyNormalization(
    repositories['gsy']!,
    _families['gsy']!,
  );
  final normalizedGsyBytes = gsyNormalization.normalizedBytesByPath;
  final gitjournalNormalization = _buildGitjournalNormalization(
    repositories['gitjournal']!,
    _families['gitjournal']!,
  );
  final normalizedGitjournalBytes =
      gitjournalNormalization.normalizedBytesByPath;
  final smoothNormalization = await _buildSmoothNormalization(
    repositories['smooth']!,
    _families['smooth']!,
    options['smooth-flutter']!,
  );
  final normalizedSmoothBytes = smoothNormalization.normalizedBytesByPath;

  final gitjournalToolchain = _probeGitjournalToolchain(
    repositories['gitjournal']!,
    options['gitjournal-flutter']!,
  );
  final publicSurface = await _capturePublicSurface();

  final allCases = <Map<String, Object?>>[];
  final familyRecords = <Map<String, Object?>>[];
  for (final project in _families.keys) {
    final spec = _families[project]!;
    final repository = repositories[project]!;
    final arbPaths =
        _gitPaths(repository, spec.revision)
            .where(
              (path) =>
                  path.startsWith('${spec.arbDirectory}/') &&
                  path.endsWith('.arb'),
            )
            .toList()
          ..sort();
    _require(
      arbPaths.contains(spec.templateArb),
      'missing ${spec.templateArb}',
    );

    final arbObjects = <String, Map<String, Object?>>{};
    for (final relativePath in arbPaths) {
      final bytes =
          project == 'gsy' && normalizedGsyBytes.containsKey(relativePath)
          ? normalizedGsyBytes[relativePath]!
          : project == 'gitjournal' &&
                normalizedGitjournalBytes.containsKey(relativePath)
          ? normalizedGitjournalBytes[relativePath]!
          : project == 'smooth' &&
                normalizedSmoothBytes.containsKey(relativePath)
          ? normalizedSmoothBytes[relativePath]!
          : _gitBlob(repository, spec.revision, relativePath);
      arbObjects[relativePath] = _jsonObject(jsonDecode(utf8.decode(bytes)));
    }
    final template = arbObjects[spec.templateArb]!;
    final cases = _jsonObjectList(oracleDocuments[project]!['cases']);
    for (final sourceCase in cases) {
      final id = sourceCase['id'];
      final key = sourceCase['detailValue'];
      var label = sourceCase['label'];
      final scannerPresence = sourceCase['observedFinding'];
      _require(
        id is String && id.startsWith('$project:l10n:'),
        'invalid case id',
      );
      _require(key is String && key.isNotEmpty, 'invalid decoded key for $id');
      _require(template.containsKey(key), '$project template is missing $key');
      _require(
        label == 'CONFIRMED_UNUSED' || label == 'CONFIRMED_USED',
        'invalid truth label for $id',
      );
      if (project == 'smooth' && _smoothFullPolicyCorrections.contains(key)) {
        _require(
          label == 'CONFIRMED_UNUSED' && scannerPresence == false,
          'Smooth correction source authority drifted for $id',
        );
        label = 'CONFIRMED_USED';
      }
      _require(scannerPresence is bool, 'invalid scanner presence for $id');
      final decodedKey = key as String;

      final record = <String, Object?>{
        'canonicalNodeId': id,
        'project': project,
        'decodedKey': decodedKey,
        'truthLabel': label == 'CONFIRMED_UNUSED'
            ? 'mutation-positive'
            : 'mutation-negative',
        'expectedScannerPresence': scannerPresence,
      };
      if (label == 'CONFIRMED_UNUSED') {
        final membersByPath = SplayTreeMap<String, Object?>();
        for (final entry in arbObjects.entries) {
          if (!entry.value.containsKey(decodedKey)) continue;
          final members = <String>[decodedKey];
          if (entry.value.containsKey('@$decodedKey')) {
            members.add('@$decodedKey');
          }
          members.sort();
          membersByPath[entry.key] = members;
        }
        _require(membersByPath.isNotEmpty, 'no mutation members for $id');
        record['expectedArbMembersByPath'] = membersByPath;
      }
      allCases.add(record);
    }

    familyRecords.add(
      _familyRecord(
        spec,
        repository,
        corpusRoot,
        arbPaths,
        project == 'gitjournal' ? gitjournalToolchain : null,
      ),
    );
  }

  allCases.sort(
    (left, right) => (left['canonicalNodeId'] as String).compareTo(
      right['canonicalNodeId'] as String,
    ),
  );
  familyRecords.sort(
    (left, right) =>
        (left['project'] as String).compareTo(right['project'] as String),
  );
  _validateCases(allCases);

  final positiveCount = allCases
      .where((entry) => entry['truthLabel'] == 'mutation-positive')
      .length;
  final negativeCount = allCases.length - positiveCount;
  _require(
    positiveCount == 367,
    'positive denominator drifted to $positiveCount',
  );
  _require(
    negativeCount == 2235,
    'negative denominator drifted to $negativeCount',
  );

  final manifest = <String, Object?>{
    'schemaVersion': 1,
    'oracleVersion': 'l10n-mutation-readiness-v2',
    'sourceOracles': sourceOracles,
    'oracleCorrections': {
      'policy': 'full-production-verification-policy',
      'reclassifiedCaseIds': [
        for (final key in _smoothFullPolicyCorrections.toList()..sort())
          'smooth:l10n:$key',
      ],
      'sourceTruthLabel': 'mutation-positive',
      'correctedTruthLabel': 'mutation-negative',
    },
    'totals': {
      'positiveKeys': positiveCount,
      'negativeKeys': negativeCount,
      'families': 3,
      'individualMutationAttempts': positiveCount,
      'familyMutationAttempts': 3,
      'requiredRestorations': positiveCount + 3,
    },
    'families': familyRecords,
    'cases': allCases,
    'mutationNegativeFixtures': _negativeFixtures,
    'publicSurfaceBaseline': publicSurface,
  };

  outputDirectory.createSync(recursive: true);
  _writeCanonicalJson(
    File(p.join(outputDirectory.path, 'gsy-normalized-family-v2.json')),
    gsyNormalization.manifest,
  );
  _writeCanonicalJson(
    File(p.join(outputDirectory.path, 'gitjournal-normalized-family-v1.json')),
    gitjournalNormalization.manifest,
  );
  _writeCanonicalJson(
    File(p.join(outputDirectory.path, 'smooth-normalized-family-v2.json')),
    smoothNormalization.manifest,
  );
  _writeCanonicalJson(
    File(p.join(outputDirectory.path, 'l10n-mutation-readiness-v2.json')),
    manifest,
  );

  for (final entry in repositories.entries) {
    final finalState = _repositoryStatus(entry.value);
    _require(
      _bytesEqual(finalState, initialRepositoryStates[entry.key]!),
      '${entry.key} repository state changed while building the manifest',
    );
  }
}

Map<String, String> _parseArguments(List<String> arguments) {
  const names = {
    'evidence-root',
    'smooth-repository',
    'gsy-repository',
    'gitjournal-repository',
    'gitjournal-flutter',
    'smooth-flutter',
    'output-directory',
  };
  final result = <String, String>{};
  for (var index = 0; index < arguments.length; index += 2) {
    _require(
      index + 1 < arguments.length,
      'missing value for ${arguments[index]}',
    );
    final token = arguments[index];
    _require(token.startsWith('--'), 'expected option, got $token');
    final name = token.substring(2);
    _require(names.contains(name), 'unknown option --$name');
    _require(!result.containsKey(name), 'duplicate option --$name');
    result[name] = arguments[index + 1];
  }
  for (final name in names) {
    _require(result[name]?.isNotEmpty ?? false, 'missing --$name');
  }
  return result;
}

void _verifyRepository(Directory repository, String revision) {
  _require(
    repository.existsSync(),
    'repository does not exist: ${repository.path}',
  );
  final head = _gitText(repository, ['rev-parse', 'HEAD']).trim();
  _require(head == revision, 'repository HEAD $head does not match $revision');
  _gitBytes(repository, ['cat-file', '-e', '$revision^{commit}']);
}

Uint8List _repositoryStatus(Directory repository) {
  return _gitBytes(repository, ['status', '--porcelain=v1', '-z']);
}

List<String> _gitPaths(Directory repository, String revision) {
  final bytes = _gitBytes(repository, [
    'ls-tree',
    '-r',
    '--name-only',
    '-z',
    revision,
  ]);
  return utf8
      .decode(bytes)
      .split('\u0000')
      .where((path) => path.isNotEmpty)
      .toList(growable: false);
}

Uint8List _gitBlob(Directory repository, String revision, String relativePath) {
  return _gitBytes(repository, ['cat-file', 'blob', '$revision:$relativePath']);
}

String _gitText(Directory repository, List<String> arguments) {
  return utf8.decode(_gitBytes(repository, arguments));
}

Uint8List _gitBytes(Directory repository, List<String> arguments) {
  final result = Process.runSync(
    'git',
    ['-C', repository.path, ...arguments],
    stdoutEncoding: null,
    stderrEncoding: utf8,
  );
  _require(
    result.exitCode == 0,
    'git ${arguments.join(' ')} failed: ${result.stderr}',
  );
  return Uint8List.fromList((result.stdout as List<int>));
}

_NormalizationResult _buildGsyNormalization(
  Directory repository,
  _FamilySpec spec,
) {
  final normalized = <String, Uint8List>{};
  final changedArbs = <Map<String, Object?>>[];
  final arbPaths =
      _gitPaths(repository, spec.revision)
          .where(
            (path) =>
                path.startsWith('${spec.arbDirectory}/') &&
                path.endsWith('.arb'),
          )
          .toList()
        ..sort();
  for (final relativePath in arbPaths) {
    final original = _gitBlob(repository, spec.revision, relativePath);
    final originalMembers = _scanTopLevelMembers(original);
    final indicesByKey = <String, List<int>>{};
    for (var index = 0; index < originalMembers.length; index++) {
      indicesByKey
          .putIfAbsent(originalMembers[index].decodedKey, () => <int>[])
          .add(index);
    }
    final copied = <_ByteCopy>[];
    final removed = <_ByteSpan>[];
    for (final indices in indicesByKey.values) {
      if (indices.length < 2) continue;
      final first = originalMembers[indices.first];
      final effective = originalMembers[indices.last];
      copied.add(
        _ByteCopy(
          first.start,
          first.endExclusive,
          effective.start,
          effective.endExclusive,
        ),
      );
      for (final index in indices.skip(1)) {
        final member = originalMembers[index];
        _require(
          member.commaEnd != null,
          'duplicate final member in $relativePath',
        );
        removed.add(_ByteSpan(member.start, member.commaEnd!));
      }
    }
    copied.sort((left, right) => left.start.compareTo(right.start));
    removed.sort((left, right) => left.start.compareTo(right.start));
    final targetSpans = <_ByteSpan>[
      for (final copy in copied) _ByteSpan(copy.start, copy.endExclusive),
      ...removed,
    ]..sort((left, right) => left.start.compareTo(right.start));
    for (var index = 1; index < targetSpans.length; index++) {
      _require(
        targetSpans[index - 1].endExclusive <= targetSpans[index].start,
        'overlapping normalization transforms in $relativePath',
      );
    }
    final replacement = _applyByteTransforms(original, copied, removed);
    final replacementMembers = _scanTopLevelMembers(replacement);
    final replacementKeys = <String>{};
    for (final member in replacementMembers) {
      _require(
        replacementKeys.add(member.decodedKey),
        'duplicate decoded key remains in $relativePath',
      );
    }
    final firstOccurrenceKeys = <String>[];
    final seenOriginalKeys = <String>{};
    for (final member in originalMembers) {
      if (seenOriginalKeys.add(member.decodedKey)) {
        firstOccurrenceKeys.add(member.decodedKey);
      }
    }
    _require(
      _sameStrings(
        replacementMembers.map((member) => member.decodedKey).toList(),
        firstOccurrenceKeys,
      ),
      'first-occurrence order changed in $relativePath',
    );
    final originalObject = _jsonObject(jsonDecode(utf8.decode(original)));
    final replacementObject = _jsonObject(jsonDecode(utf8.decode(replacement)));
    final canonicalObject = _canonicalCompact(originalObject);
    _require(
      canonicalObject == _canonicalCompact(replacementObject),
      'decoded-object equivalence failed for $relativePath',
    );
    normalized[relativePath] = replacement;
    if (removed.isNotEmpty) {
      changedArbs.add({
        'relativePath': relativePath,
        'originalSha256': _sha256(original),
        'copiedByteSpans': [
          for (final copy in copied)
            {
              'start': copy.start,
              'endExclusive': copy.endExclusive,
              'sourceStart': copy.sourceStart,
              'sourceEndExclusive': copy.sourceEndExclusive,
            },
        ],
        'removedByteSpans': [
          for (final span in removed)
            {'start': span.start, 'endExclusive': span.endExclusive},
        ],
        'replacementSha256': _sha256(replacement),
        'canonicalDecodedObjectSha256': _sha256(utf8.encode(canonicalObject)),
        'decodedObjectEquivalent': true,
        'replacementHasDuplicateDecodedKeys': false,
      });
    }
  }
  _require(changedArbs.isNotEmpty, 'GSY has no duplicate decoded members');
  return _NormalizationResult(
    normalizedBytesByPath: normalized,
    manifest: {
      'schemaVersion': 2,
      'normalizationVersion': 'gsy-normalized-family-v2',
      'repositorySha': spec.revision,
      'policy':
          'retain-last-effective-decoded-top-level-member-at-first-position',
      'changedArbs': changedArbs,
    },
  );
}

_NormalizationResult _buildGitjournalNormalization(
  Directory repository,
  _FamilySpec spec,
) {
  final normalized = <String, Uint8List>{};
  final changedArbs = <Map<String, Object?>>[];
  final arbPaths =
      _gitPaths(repository, spec.revision)
          .where(
            (path) =>
                path.startsWith('${spec.arbDirectory}/') &&
                path.endsWith('.arb'),
          )
          .toList()
        ..sort();
  for (final relativePath in arbPaths) {
    final original = _gitBlob(repository, spec.revision, relativePath);
    final members = _scanTopLevelMembers(original);
    final removed = <_ByteSpan>[];
    for (final member in members) {
      final remove =
          member.decodedKey == 'settingsExperimentalMerge' ||
          relativePath == 'lib/l10n/app_ru.arb' &&
              member.decodedKey == '@rootFolder';
      if (!remove) continue;
      _require(
        member.commaEnd != null,
        'GitJournal ignored member must not be final in $relativePath',
      );
      removed.add(_ByteSpan(member.start, member.commaEnd!));
    }
    removed.sort((left, right) => left.start.compareTo(right.start));
    final replacement = _applyByteTransforms(original, const [], removed);
    final replacementMembers = _scanTopLevelMembers(replacement);
    final replacementKeys = <String>{};
    for (final member in replacementMembers) {
      _require(
        replacementKeys.add(member.decodedKey),
        'duplicate decoded key remains in $relativePath',
      );
    }
    final replacementObject = _jsonObject(jsonDecode(utf8.decode(replacement)));
    final canonicalReplacement = _canonicalCompact(replacementObject);
    normalized[relativePath] = replacement;
    if (removed.isNotEmpty) {
      changedArbs.add({
        'relativePath': relativePath,
        'originalSha256': _sha256(original),
        'copiedByteSpans': const <Object?>[],
        'removedByteSpans': [
          for (final span in removed)
            {'start': span.start, 'endExclusive': span.endExclusive},
        ],
        'replacementSha256': _sha256(replacement),
        'canonicalDecodedObjectSha256': _sha256(
          utf8.encode(canonicalReplacement),
        ),
        'decodedObjectEquivalent': false,
        'replacementHasDuplicateDecodedKeys': false,
      });
    }
  }
  _require(
    changedArbs.length == 21,
    'GitJournal normalized ARB count drifted to ${changedArbs.length}',
  );
  return _NormalizationResult(
    normalizedBytesByPath: normalized,
    manifest: {
      'schemaVersion': 2,
      'normalizationVersion': 'gitjournal-normalized-family-v1',
      'repositorySha': spec.revision,
      'policy': 'remove-generator-ignored-extraneous-members',
      'changedArbs': changedArbs,
    },
  );
}

Future<_NormalizationResult> _buildSmoothNormalization(
  Directory repository,
  _FamilySpec spec,
  String flutterExecutable,
) async {
  final normalized = <String, Uint8List>{};
  final changedArbs = <Map<String, Object?>>[];
  final arbPaths =
      _gitPaths(repository, spec.revision)
          .where(
            (path) =>
                path.startsWith('${spec.arbDirectory}/') &&
                path.endsWith('.arb'),
          )
          .toList()
        ..sort();
  final templateObject = _jsonObject(
    jsonDecode(
      utf8.decode(_gitBlob(repository, spec.revision, spec.templateArb)),
    ),
  );
  final invalidTemplateMetadataKeys = <String>{
    for (final entry in templateObject.entries)
      if (entry.key.startsWith('@') &&
          !entry.key.startsWith('@@') &&
          (templateObject[entry.key.substring(1)] is! String ||
              !_sameStringSets(
                _metadataPlaceholderNames(entry.value),
                _messagePlaceholderNames(
                  templateObject[entry.key.substring(1)]! as String,
                ),
              )))
        entry.key,
  };
  for (final relativePath in arbPaths) {
    final original = _gitBlob(repository, spec.revision, relativePath);
    final members = _scanTopLevelMembers(original);
    final object = _jsonObject(jsonDecode(utf8.decode(original)));
    final decodedKeys = members.map((member) => member.decodedKey).toSet();
    final isTemplate = relativePath == spec.templateArb;
    final invalidLocaleMessageKeys = <String>{
      if (!isTemplate)
        for (final entry in object.entries)
          if (!entry.key.startsWith('@') &&
              (entry.value is! String ||
                  templateObject[entry.key] is! String ||
                  !_sameStringSets(
                    _messagePlaceholderNames(entry.value as String),
                    _messagePlaceholderNames(
                      templateObject[entry.key]! as String,
                    ),
                  )))
            entry.key,
    };
    final removedIndices = <int>[];
    for (var index = 0; index < members.length; index++) {
      final member = members[index];
      final key = member.decodedKey;
      final isMetadata = key.startsWith('@') && !key.startsWith('@@');
      final metadataOwner = isMetadata ? key.substring(1) : null;
      final removeMetadata =
          isMetadata &&
          (!decodedKeys.contains(metadataOwner) ||
              invalidLocaleMessageKeys.contains(metadataOwner) ||
              invalidTemplateMetadataKeys.contains(key) ||
              isTemplate &&
                  object[metadataOwner] is String &&
                  !_sameStringSets(
                    _metadataPlaceholderNames(object[key]),
                    _messagePlaceholderNames(object[metadataOwner]! as String),
                  ) ||
              !isTemplate &&
                  (templateObject[metadataOwner] is! String ||
                      templateObject[key] is! Map ||
                      !_sameStringSets(
                        _metadataPlaceholderNames(object[key]),
                        _metadataPlaceholderNames(templateObject[key]),
                      )));
      final removeLocaleMessage =
          !key.startsWith('@') && invalidLocaleMessageKeys.contains(key);
      if (!removeMetadata && !removeLocaleMessage) continue;
      removedIndices.add(index);
    }
    final removed = <_ByteSpan>[];
    for (var cursor = 0; cursor < removedIndices.length;) {
      final first = removedIndices[cursor];
      var last = first;
      cursor++;
      while (cursor < removedIndices.length &&
          removedIndices[cursor] == last + 1) {
        last = removedIndices[cursor];
        cursor++;
      }
      if (last < members.length - 1) {
        removed.add(_ByteSpan(members[first].start, members[last].commaEnd!));
      } else {
        _require(first > 0, 'Smooth normalization cannot remove every member');
        removed.add(
          _ByteSpan(
            members[first - 1].endExclusive,
            members[last].endExclusive,
          ),
        );
      }
    }
    removed.sort((left, right) => left.start.compareTo(right.start));
    final replacement = _applyByteTransforms(original, const [], removed);
    final replacementMembers = _scanTopLevelMembers(replacement);
    final replacementKeys = <String>{};
    for (final member in replacementMembers) {
      _require(
        replacementKeys.add(member.decodedKey),
        'duplicate decoded key remains in $relativePath',
      );
      final key = member.decodedKey;
      _require(
        !key.startsWith('@') ||
            key.startsWith('@@') ||
            replacementKeys.contains(key.substring(1)) ||
            replacementMembers.any(
              (candidate) => candidate.decodedKey == key.substring(1),
            ),
        'orphan metadata remains in $relativePath',
      );
    }
    final replacementObject = _jsonObject(jsonDecode(utf8.decode(replacement)));
    final canonicalReplacement = _canonicalCompact(replacementObject);
    normalized[relativePath] = replacement;
    if (removed.isNotEmpty) {
      changedArbs.add({
        'relativePath': relativePath,
        'originalSha256': _sha256(original),
        'copiedByteSpans': const <Object?>[],
        'removedByteSpans': [
          for (final span in removed)
            {'start': span.start, 'endExclusive': span.endExclusive},
        ],
        'replacementSha256': _sha256(replacement),
        'canonicalDecodedObjectSha256': _sha256(
          utf8.encode(canonicalReplacement),
        ),
        'decodedObjectEquivalent': false,
        'replacementHasDuplicateDecodedKeys': false,
      });
    }
  }
  _require(
    changedArbs.length == arbPaths.length,
    'Smooth orphan-metadata normalization membership drifted: '
    '${changedArbs.length}/${arbPaths.length}',
  );
  final generatedBaseline = await _buildSmoothGeneratedBaseline(
    repository: repository,
    spec: spec,
    normalizedBytesByPath: normalized,
    flutterExecutable: flutterExecutable,
  );
  return _NormalizationResult(
    normalizedBytesByPath: normalized,
    manifest: {
      'schemaVersion': 3,
      'normalizationVersion': 'smooth-normalized-family-v2',
      'repositorySha': spec.revision,
      'policy': 'remove-generator-ignored-or-inconsistent-locale-members',
      'changedArbs': changedArbs,
      'generatedBaseline': {
        'policy': 'regenerate-after-normalization-with-pinned-toolchain',
        'changedOutputs': generatedBaseline,
      },
    },
  );
}

Future<List<Map<String, Object?>>> _buildSmoothGeneratedBaseline({
  required Directory repository,
  required _FamilySpec spec,
  required Map<String, Uint8List> normalizedBytesByPath,
  required String flutterExecutable,
}) async {
  _require(
    Platform.isMacOS || Platform.isLinux,
    'Smooth generated baseline requires POSIX mode authority',
  );
  final flutter = File(flutterExecutable);
  _require(
    FileSystemEntity.typeSync(flutter.path, followLinks: false) ==
        FileSystemEntityType.file,
    'Smooth Flutter executable is not a regular file',
  );
  final canonicalFlutter = flutter.resolveSymbolicLinksSync();
  final probeBefore = await _runRequired(canonicalFlutter, const [
    '--version',
    '--machine',
  ], workingDirectory: flutter.parent.path);
  _validateSmoothToolchain(probeBefore.stdout as String);

  final ownedRoot = Directory.systemTemp.createTempSync(
    'flutter-pruner-smooth-normalization-builder-',
  );
  final clone = Directory(p.join(ownedRoot.path, 'repository'));
  try {
    await _runRequired('git', [
      'clone',
      '--quiet',
      '--no-local',
      '--no-hardlinks',
      '--no-checkout',
      '--no-tags',
      repository.path,
      clone.path,
    ], workingDirectory: ownedRoot.path);
    await _runRequired('git', [
      '-C',
      clone.path,
      'checkout',
      '--detach',
      '--force',
      spec.revision,
    ], workingDirectory: ownedRoot.path);
    await _runRequired('git', [
      '-C',
      clone.path,
      'remote',
      'remove',
      'origin',
    ], workingDirectory: ownedRoot.path);
    final packageRoot = Directory(p.join(clone.path, spec.packageRoot));
    await _runRequired(canonicalFlutter, const [
      'pub',
      'get',
      '--offline',
    ], workingDirectory: packageRoot.path);
    for (final entry in normalizedBytesByPath.entries) {
      final target = File(p.joinAll([clone.path, ...entry.key.split('/')]));
      _require(target.existsSync(), 'normalized Smooth ARB is missing');
      target.writeAsBytesSync(entry.value, flush: true);
      _require(
        _sha256(target.readAsBytesSync()) == _sha256(entry.value),
        'normalized Smooth ARB installation drifted',
      );
    }
    final before = _regularFileStates(packageRoot);
    await _runRequired(canonicalFlutter, const [
      'gen-l10n',
    ], workingDirectory: packageRoot.path);
    final after = _regularFileStates(packageRoot);
    final paths = <String>{...before.keys, ...after.keys}.toList()..sort();
    final changed = <String>[
      for (final path in paths)
        if (before[path] != after[path]) path,
    ];
    _require(
      changed.length == 64,
      'Smooth normalized generated output count drifted to ${changed.length}',
    );
    final arbDirectoryWithinPackage = p
        .relative(spec.arbDirectory, from: spec.packageRoot)
        .replaceAll('\\', '/');
    final records = <Map<String, Object?>>[];
    for (final packagePath in changed) {
      final original = before[packagePath];
      final replacement = after[packagePath];
      _require(
        original != null &&
            replacement != null &&
            packagePath.startsWith('$arbDirectoryWithinPackage/') &&
            packagePath.endsWith('.dart') &&
            original.sha256 != replacement.sha256 &&
            original.posixMode == replacement.posixMode,
        'Smooth normalized generator changed an unauthorized path',
      );
      records.add({
        'relativePath': p.posix.join(spec.packageRoot, packagePath),
        'originalSha256': original!.sha256,
        'replacementSha256': replacement!.sha256,
        'posixMode': original.posixMode,
      });
    }
    final probeAfter = await _runRequired(canonicalFlutter, const [
      '--version',
      '--machine',
    ], workingDirectory: flutter.parent.path);
    _validateSmoothToolchain(probeAfter.stdout as String);
    _require(
      probeBefore.stdout == probeAfter.stdout,
      'Smooth Flutter machine identity drifted during generation',
    );
    return records;
  } finally {
    if (ownedRoot.existsSync()) ownedRoot.deleteSync(recursive: true);
  }
}

Future<ProcessResult> _runRequired(
  String executable,
  List<String> arguments, {
  required String workingDirectory,
}) async {
  final result = await Process.run(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    environment: const {
      'CI': 'true',
      'FLUTTER_SUPPRESS_ANALYTICS': 'true',
      'LANG': 'en_US.UTF-8',
      'LC_ALL': 'en_US.UTF-8',
    },
    includeParentEnvironment: true,
  );
  _require(
    result.exitCode == 0,
    '$executable ${arguments.join(' ')} failed: ${result.stderr}',
  );
  return result;
}

void _validateSmoothToolchain(String rawMachine) {
  final machine = _jsonObject(jsonDecode(rawMachine));
  _require(machine['frameworkVersion'] == '3.44.9', 'Smooth Flutter drifted');
  _require(
    machine['frameworkRevision'] == _smoothFrameworkRevision,
    'Smooth framework revision drifted',
  );
  _require(
    machine['engineRevision'] == _smoothEngineRevision,
    'Smooth engine revision drifted',
  );
  _require(
    machine['dartSdkVersion'] == _smoothDartVersion,
    'Smooth Dart SDK drifted',
  );
}

Map<String, ({String sha256, int posixMode})> _regularFileStates(
  Directory root,
) {
  final states = <String, ({String sha256, int posixMode})>{};
  for (final entity in root.listSync(recursive: true, followLinks: false)) {
    if (FileSystemEntity.typeSync(entity.path, followLinks: false) !=
        FileSystemEntityType.file) {
      continue;
    }
    final relativePath = p
        .relative(entity.path, from: root.path)
        .replaceAll('\\', '/');
    final file = File(entity.path);
    states[relativePath] = (
      sha256: _sha256(file.readAsBytesSync()),
      posixMode: file.statSync().mode & 0xfff,
    );
  }
  return states;
}

List<_JsonMember> _scanTopLevelMembers(List<int> bytes) {
  var cursor = _skipWhitespace(bytes, 0);
  _require(
    cursor < bytes.length && bytes[cursor] == 0x7b,
    'expected JSON object',
  );
  cursor++;
  final members = <_JsonMember>[];
  while (true) {
    cursor = _skipWhitespace(bytes, cursor);
    if (cursor < bytes.length && bytes[cursor] == 0x7d) {
      cursor++;
      break;
    }
    _require(
      cursor < bytes.length && bytes[cursor] == 0x22,
      'expected JSON key',
    );
    final start = cursor;
    final keyEnd = _skipString(bytes, cursor);
    final decodedKey =
        jsonDecode(utf8.decode(bytes.sublist(cursor, keyEnd))) as String;
    cursor = _skipWhitespace(bytes, keyEnd);
    _require(cursor < bytes.length && bytes[cursor] == 0x3a, 'expected colon');
    cursor = _skipWhitespace(bytes, cursor + 1);
    cursor = _skipJsonValue(bytes, cursor);
    cursor = _skipWhitespace(bytes, cursor);
    int? commaEnd;
    if (cursor < bytes.length && bytes[cursor] == 0x2c) {
      commaEnd = cursor + 1;
      cursor++;
    } else {
      _require(
        cursor < bytes.length && bytes[cursor] == 0x7d,
        'expected comma',
      );
    }
    members.add(
      _JsonMember(
        start,
        cursor - (commaEnd == null ? 0 : 1),
        commaEnd,
        decodedKey,
      ),
    );
  }
  _require(
    _skipWhitespace(bytes, cursor) == bytes.length,
    'trailing JSON bytes',
  );
  return members;
}

int _skipWhitespace(List<int> bytes, int cursor) {
  while (cursor < bytes.length &&
      (bytes[cursor] == 0x20 ||
          bytes[cursor] == 0x09 ||
          bytes[cursor] == 0x0a ||
          bytes[cursor] == 0x0d)) {
    cursor++;
  }
  return cursor;
}

int _skipString(List<int> bytes, int cursor) {
  _require(bytes[cursor] == 0x22, 'expected string');
  cursor++;
  while (cursor < bytes.length) {
    if (bytes[cursor] == 0x5c) {
      cursor += 2;
      continue;
    }
    if (bytes[cursor] == 0x22) return cursor + 1;
    cursor++;
  }
  throw StateError('unterminated JSON string');
}

int _skipJsonValue(List<int> bytes, int cursor) {
  if (bytes[cursor] == 0x22) return _skipString(bytes, cursor);
  if (bytes[cursor] == 0x7b || bytes[cursor] == 0x5b) {
    final stack = <int>[bytes[cursor] == 0x7b ? 0x7d : 0x5d];
    cursor++;
    while (cursor < bytes.length && stack.isNotEmpty) {
      final byte = bytes[cursor];
      if (byte == 0x22) {
        cursor = _skipString(bytes, cursor);
      } else if (byte == 0x7b || byte == 0x5b) {
        stack.add(byte == 0x7b ? 0x7d : 0x5d);
        cursor++;
      } else if (byte == stack.last) {
        stack.removeLast();
        cursor++;
      } else {
        cursor++;
      }
    }
    _require(stack.isEmpty, 'unterminated JSON value');
    return cursor;
  }
  while (cursor < bytes.length &&
      bytes[cursor] != 0x2c &&
      bytes[cursor] != 0x7d &&
      bytes[cursor] != 0x5d &&
      bytes[cursor] != 0x20 &&
      bytes[cursor] != 0x09 &&
      bytes[cursor] != 0x0a &&
      bytes[cursor] != 0x0d) {
    cursor++;
  }
  return cursor;
}

Uint8List _applyByteTransforms(
  List<int> source,
  List<_ByteCopy> copied,
  List<_ByteSpan> removed,
) {
  final transforms =
      <
          ({
            int start,
            int endExclusive,
            int? sourceStart,
            int? sourceEndExclusive,
          })
        >[
          for (final copy in copied)
            (
              start: copy.start,
              endExclusive: copy.endExclusive,
              sourceStart: copy.sourceStart,
              sourceEndExclusive: copy.sourceEndExclusive,
            ),
          for (final span in removed)
            (
              start: span.start,
              endExclusive: span.endExclusive,
              sourceStart: null,
              sourceEndExclusive: null,
            ),
        ]
        ..sort((left, right) => left.start.compareTo(right.start));
  final builder = BytesBuilder(copy: false);
  var cursor = 0;
  for (final transform in transforms) {
    builder.add(source.sublist(cursor, transform.start));
    if (transform.sourceStart case final sourceStart?) {
      builder.add(source.sublist(sourceStart, transform.sourceEndExclusive));
    }
    cursor = transform.endExclusive;
  }
  builder.add(source.sublist(cursor));
  return builder.takeBytes();
}

bool _sameStrings(List<String> left, List<String> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

Set<String> _messagePlaceholderNames(String message) => RegExp(
  r'\{\s*([A-Za-z_]\w*)\s*(?:\}|,)',
).allMatches(message).map((match) => match.group(1)!).toSet();

Set<String> _metadataPlaceholderNames(Object? metadata) {
  if (metadata is! Map) return const {};
  final placeholders = metadata['placeholders'];
  return placeholders is Map
      ? placeholders.keys.whereType<String>().toSet()
      : const {};
}

bool _sameStringSets(Set<String> left, Set<String> right) =>
    left.length == right.length && left.containsAll(right);

Map<String, Object?> _probeGitjournalToolchain(
  Directory repository,
  String flutterExecutable,
) {
  final pubspec = _gitBlob(
    repository,
    _families['gitjournal']!.revision,
    'pubspec.yaml',
  );
  final workflow = _gitBlob(
    repository,
    _families['gitjournal']!.revision,
    '.github/workflows/lint.yml',
  );
  final evidence = BytesBuilder(copy: false)
    ..add(pubspec)
    ..addByte(0)
    ..add(workflow);
  _require(
    _sha256(evidence.takeBytes()) == _gitjournalCiEvidenceHash,
    'GitJournal CI-resolution evidence drifted',
  );
  final pubspecText = utf8.decode(pubspec);
  final workflowText = utf8.decode(workflow);
  _require(
    pubspecText.contains('flutter: ">=3.41.5"'),
    'missing Flutter floor',
  );
  _require(
    workflowText.contains('flutter-version: \${{ env.FLUTTER_VERSION }}'),
    'missing CI Flutter version resolution',
  );

  final result = Process.runSync(
    flutterExecutable,
    ['--version', '--machine'],
    stdoutEncoding: null,
    stderrEncoding: utf8,
  );
  _require(
    result.exitCode == 0,
    'GitJournal Flutter probe failed: ${result.stderr}',
  );
  final output = Uint8List.fromList(result.stdout as List<int>);
  _require(output.length <= 16384, 'GitJournal Flutter probe exceeded 16 KiB');
  _require(
    _sha256(output) == _gitjournalProbeHash,
    'Flutter probe bytes drifted',
  );
  final machine = _jsonObject(jsonDecode(utf8.decode(output)));
  _require(
    machine['frameworkVersion'] == '3.41.5',
    'framework version drifted',
  );
  _require(
    machine['frameworkRevision'] == _gitjournalFrameworkRevision,
    'framework revision drifted',
  );
  _require(
    machine['engineRevision'] == _gitjournalEngineRevision,
    'engine revision drifted',
  );
  _require(machine['dartSdkVersion'] == _gitjournalDartVersion, 'Dart drifted');
  return {
    'frameworkVersion': '3.41.5',
    'frameworkRevision': _gitjournalFrameworkRevision,
    'engineRevision': _gitjournalEngineRevision,
    'bundledDartVersion': _gitjournalDartVersion,
    'ciResolutionEvidenceSha256': _gitjournalCiEvidenceHash,
    'probeArgv': ['flutter', '--version', '--machine'],
    'boundedProbeOutputSha256': _gitjournalProbeHash,
  };
}

Map<String, Object?> _familyRecord(
  _FamilySpec spec,
  Directory repository,
  Directory corpusRoot,
  List<String> arbPaths,
  Map<String, Object?>? gitjournalToolchain,
) {
  final fixtureOverlays = _verifiedFixtureOverlays(spec.project, corpusRoot);
  final toolchain =
      gitjournalToolchain ??
      (spec.project == 'smooth'
          ? {
              'evidencePath': '.fvmrc',
              'evidenceSha256': fixtureOverlays.singleWhere(
                (overlay) => overlay['relativePath'] == '.fvmrc',
              )['sha256'],
              'frameworkVersion': spec.frameworkVersion,
              'selectionKind': 'pinned-fvm-config',
            }
          : _fvmToolchainSelectionEvidence(repository, spec));
  final policy = <Map<String, Object?>>[];
  if (spec.project == 'smooth') {
    policy.add({
      'workingDirectory': spec.packageRoot,
      'executable': {
        'kind': 'flutterByVersion',
        'version': spec.frameworkVersion,
      },
      'arguments': ['analyze', '--no-pub', '--fatal-infos', '--fatal-warnings'],
    });
    policy.add({
      'workingDirectory': spec.packageRoot,
      'executable': {
        'kind': 'flutterByVersion',
        'version': spec.frameworkVersion,
      },
      'arguments': ['test', '--no-pub'],
    });
  } else {
    for (final command in const ['analyze', 'test']) {
      final arguments = command == 'analyze' && spec.project == 'gitjournal'
          ? const ['analyze', '--no-pub', '--no-fatal-infos']
          : [command, '--no-pub'];
      policy.add({
        'workingDirectory': spec.packageRoot,
        'executable': {
          'kind': 'flutterByVersion',
          'version': spec.frameworkVersion,
        },
        'arguments': arguments,
      });
    }
  }
  return {
    'project': spec.project,
    'repositorySha': spec.revision,
    'packageRoot': spec.packageRoot,
    'arbDirectory': spec.arbDirectory,
    'templateArbPath': spec.templateArb,
    'arbPaths': arbPaths,
    'expectedConfigurationStatus': 'supported',
    'expectedFamilyBatchStatus': 'accepted',
    'toolchainSelectionEvidence': toolchain,
    'verificationPolicy': policy,
    'fixtureOverlays': fixtureOverlays,
    'normalizationOverlays': switch (spec.project) {
      'gsy' => [
        {
          'manifest': 'gsy-normalized-family-v2.json',
          'policy': 'apply-declared-byte-transforms',
        },
      ],
      'gitjournal' => [
        {
          'manifest': 'gitjournal-normalized-family-v1.json',
          'policy': 'apply-declared-byte-transforms',
        },
      ],
      'smooth' => [
        {
          'manifest': 'smooth-normalized-family-v2.json',
          'policy': 'apply-declared-byte-transforms',
        },
      ],
      _ => <Map<String, Object?>>[],
    },
  };
}

Directory _canonicalEvidenceRoot(Directory supplied) {
  _require(
    FileSystemEntity.typeSync(supplied.path, followLinks: false) ==
        FileSystemEntityType.directory,
    'evidence root must be an existing non-link directory: ${supplied.path}',
  );
  return Directory(supplied.resolveSymbolicLinksSync());
}

Directory _retainedCorpusRoot(Directory evidenceRoot) {
  final resultsRoot = Directory(p.dirname(evidenceRoot.path));
  _require(
    p.basename(resultsRoot.path) == 'results',
    'evidence root must be directly below the retained results directory',
  );
  final corpusRoot = Directory(p.dirname(resultsRoot.path));
  _require(
    FileSystemEntity.typeSync(corpusRoot.path, followLinks: false) ==
        FileSystemEntityType.directory,
    'retained corpus root is not a directory',
  );
  _require(
    p.isWithin(corpusRoot.path, evidenceRoot.path),
    'evidence root escapes retained corpus root',
  );
  return corpusRoot;
}

List<Map<String, Object?>> _verifiedFixtureOverlays(
  String project,
  Directory corpusRoot,
) {
  return switch (project) {
    'gsy' => [
      _verifiedFixtureOverlay(
        corpusRoot: corpusRoot,
        relativePath: 'flutter_pruner_v2_accuracy.yaml',
        sourceIdentity:
            'worktrees/v2-natural-accuracy/gsy/flutter_pruner_v2_accuracy.yaml',
        purpose: 'scanner coverage authority',
        expectedSha256:
            '088014c7fc747e62ba52e705374da2e6fb12aea87fa4f0cdd9a0d3935d916beb',
      ),
      _verifiedFixtureOverlay(
        corpusRoot: corpusRoot,
        relativePath: 'lib/common/config/ignoreConfig.dart',
        sourceIdentity:
            'worktrees/v2-natural-accuracy/gsy/lib/common/config/ignoreConfig.dart',
        purpose: 'non-secret ignored configuration stub',
        expectedSha256:
            'cb2b8ad720d95f0f0c8e633c389a5ae0dc8876e274b7455d77bb6ed9350efbbe',
      ),
    ],
    'gitjournal' => [
      _verifiedFixtureOverlay(
        corpusRoot: corpusRoot,
        relativePath: 'flutter_pruner_v2_accuracy.yaml',
        sourceIdentity:
            'worktrees/v2-natural-accuracy/gitjournal/flutter_pruner_v2_accuracy.yaml',
        purpose: 'scanner coverage authority',
        expectedSha256:
            '4231078c9d2d427da754d28395a2727ddc4a4c054790c4381de2e256d9a35d05',
      ),
      _verifiedFixtureOverlay(
        corpusRoot: corpusRoot,
        relativePath: 'lib/.env.dart',
        sourceIdentity:
            'worktrees/v2-natural-accuracy/gitjournal/lib/.env.dart',
        purpose: 'non-secret environment stub',
        expectedSha256:
            'a4aee8e49b8ae44f874ae182b464cbba1d00ba3045eaf37c14d745849da98b33',
      ),
    ],
    'smooth' => [
      _verifiedFixtureOverlay(
        corpusRoot: corpusRoot,
        relativePath: '.fvmrc',
        sourceIdentity: 'worktrees/v3-stage1/smooth/.fvmrc',
        purpose: 'toolchain selector authority',
        expectedSha256:
            'b94a21e157a4ee1f8a34fa2b69e7b9d50fe06654cdcdbe6d6df65866e7129f94',
      ),
      _verifiedFixtureOverlay(
        corpusRoot: corpusRoot,
        relativePath: 'packages/smooth_app/flutter_pruner_v2_accuracy.yaml',
        sourceIdentity:
            'worktrees/v2-natural-accuracy/smooth/packages/smooth_app/flutter_pruner_v2_accuracy.yaml',
        purpose: 'scanner coverage authority',
        expectedSha256:
            '9c50b97122bc7dc037f87f8bcd85e0ce05ba92ddadbb3d6e3ab5e52974ca3527',
      ),
    ],
    _ => throw StateError('unknown fixture overlay project'),
  };
}

Map<String, Object?> _verifiedFixtureOverlay({
  required Directory corpusRoot,
  required String relativePath,
  required String sourceIdentity,
  required String purpose,
  required String expectedSha256,
}) {
  _require(
    p.posix.normalize(sourceIdentity) == sourceIdentity &&
        !p.posix.isAbsolute(sourceIdentity) &&
        !p.posix.split(sourceIdentity).contains('..'),
    'fixture overlay source identity is not canonical: $sourceIdentity',
  );
  var currentPath = corpusRoot.path;
  for (final segment in p.posix.split(sourceIdentity)) {
    currentPath = p.join(currentPath, segment);
    final type = FileSystemEntity.typeSync(currentPath, followLinks: false);
    _require(type != FileSystemEntityType.link, 'overlay path contains a link');
  }
  final source = File(currentPath);
  _require(
    FileSystemEntity.typeSync(source.path, followLinks: false) ==
        FileSystemEntityType.file,
    'retained fixture overlay is missing or not a regular file: $sourceIdentity',
  );
  final canonicalSource = source.resolveSymbolicLinksSync();
  _require(
    p.isWithin(corpusRoot.path, canonicalSource) &&
        canonicalSource == p.normalize(source.absolute.path),
    'retained fixture overlay escapes its canonical corpus root',
  );
  final before = source.statSync();
  final bytes = source.readAsBytesSync();
  final after = source.statSync();
  _require(
    before.type == FileSystemEntityType.file &&
        after.type == FileSystemEntityType.file &&
        before.size == after.size &&
        before.modified == after.modified &&
        before.changed == after.changed &&
        source.resolveSymbolicLinksSync() == canonicalSource,
    'retained fixture overlay identity changed while reading',
  );
  final actualSha256 = _sha256(bytes);
  _require(
    actualSha256 == expectedSha256,
    'retained fixture overlay SHA-256 mismatch for $sourceIdentity: '
    '$actualSha256',
  );
  return {
    'relativePath': relativePath,
    'sourceIdentity': sourceIdentity,
    'purpose': purpose,
    'sha256': expectedSha256,
    'containsSecrets': false,
  };
}

Map<String, Object?> _fvmToolchainSelectionEvidence(
  Directory repository,
  _FamilySpec spec,
) {
  final evidence = _gitBlob(repository, spec.revision, '.fvmrc');
  final decoded = _jsonObject(jsonDecode(utf8.decode(evidence)));
  _require(
    decoded['flutter'] == spec.frameworkVersion,
    '${spec.project} .fvmrc does not select ${spec.frameworkVersion}',
  );
  return {
    'frameworkVersion': spec.frameworkVersion,
    'selectionKind': 'pinned-fvm-config',
    'evidencePath': '.fvmrc',
    'evidenceSha256': _sha256(evidence),
  };
}

Future<Map<String, Object?>> _capturePublicSurface() async {
  final scriptDirectory = p.dirname(Platform.script.toFilePath());
  final repositoryRoot = p.normalize(p.join(scriptDirectory, '..', '..'));
  final staging = _PrivateStagingRoot.create();
  final fixtureRoot = staging.directory;
  try {
    _copyDirectory(
      Directory(p.join(repositoryRoot, 'test', 'fixtures', 'l10n_test')),
      fixtureRoot,
    );
    File(p.join(fixtureRoot.path, 'lib', 'main.dart')).writeAsStringSync('''
import 'l10n/app_localizations.dart';

void main() {
  const AppLocalizations().welcome;
}
''');
    final packageConfig = File(
      p.join(fixtureRoot.path, '.dart_tool', 'package_config.json'),
    );
    packageConfig.parent.createSync(recursive: true);
    packageConfig.writeAsStringSync('''
{"configVersion":2,"packages":[
  {"name":"l10n_test","rootUri":"../","packageUri":"lib/","languageVersion":"3.9"}
]}
''');
    final config = File(
      p.join(fixtureRoot.path, '.flutter_pruner', 'config.yaml'),
    );
    config.parent.createSync(recursive: true);
    config.writeAsStringSync('''
version: 1
analysis:
  mode: application
target_matrix:
  complete: true
  targets:
    - name: android
      platform: android
      entrypoint: lib/main.dart
''');

    final topHelp = _runCli(repositoryRoot, ['--help']).stdoutBytes;
    final scanHelp = _runCli(repositoryRoot, ['scan', '--help']).stdoutBytes;
    final terminalFile = File(p.join(fixtureRoot.path, 'terminal.txt'));
    final jsonFile = File(p.join(fixtureRoot.path, 'scan.json'));
    final htmlFile = File(p.join(fixtureRoot.path, 'scan.html'));
    _runCli(repositoryRoot, [
      'scan',
      '--adapter',
      'l10n',
      '--format',
      'human',
      '--output',
      terminalFile.path,
      fixtureRoot.path,
    ]);
    _runCli(repositoryRoot, [
      'scan',
      '--adapter',
      'l10n',
      '--format',
      'json',
      '--output',
      jsonFile.path,
      fixtureRoot.path,
    ]);
    _runCli(repositoryRoot, [
      'scan',
      '--adapter',
      'l10n',
      '--format',
      'html',
      '--output',
      htmlFile.path,
      fixtureRoot.path,
    ]);

    final terminal = staging.normalize(
      _stripAnsi(terminalFile.readAsStringSync()).replaceAll('\r\n', '\n'),
    );
    final report = _jsonObject(jsonDecode(jsonFile.readAsStringSync()));
    _removeTimingFields(report);
    final normalizedReport = _jsonObject(staging.normalizeObject(report));
    final normalizedJson = _canonicalCompact(normalizedReport);
    final normalizedHtml = _normalizeHtml(
      staging.normalize(htmlFile.readAsStringSync()),
      normalizedReport,
    );
    staging.requireNormalized(terminal);
    staging.requireNormalized(normalizedJson);
    staging.requireNormalized(normalizedHtml);
    final blockers = _jsonObject(normalizedReport['blockers']);
    final findings = <Map<String, Object?>>[];
    for (final finding in _jsonObjectList(normalizedReport['findings'])) {
      final node = _jsonObject(finding['node']);
      final blockerIds = (finding['blockerIds'] as List<Object?>? ?? const [])
          .cast<String>();
      for (final blockerId in blockerIds) {
        _require(blockers.containsKey(blockerId), 'missing blocker $blockerId');
      }
      findings.add({
        'id': node['id'],
        'tier': finding['confidence'],
        'classificationReasons': finding['classificationReasons'],
        'blockerIdentities': blockerIds,
      });
    }
    final optionNames = <String>{};
    final optionPattern = RegExp(r'--[a-z][a-z0-9-]*');
    for (final bytes in [topHelp, scanHelp]) {
      optionNames.addAll(
        optionPattern
            .allMatches(utf8.decode(bytes))
            .map((match) => match.group(0)!),
      );
    }
    final schemaKeys = <String>{};
    _collectSchemaKeys(normalizedReport, '', schemaKeys);
    return {
      'fixture': 'test/fixtures/l10n_test',
      'captureBoundary': 'argv-only-child-process',
      'stagingRootNormalization': {
        'creation': 'Directory.systemTemp.createTempSync',
        'stablePlaceholder': _publicSurfaceStagingPlaceholder,
        'linkPolicy': 'reject-all-links',
        'cleanupIdentity': 'canonical-path-and-exclusive-marker',
      },
      'timingFieldsRemoved': [
        'execution.analysisPasses[].adapters[].elapsedMicros',
        'execution.analysisPasses[].elapsedMicros',
        'run.elapsedMicros',
        'run.finishedAtUtc',
        'run.id',
        'run.startedAtUtc',
      ],
      'topLevelHelpSha256': _sha256(topHelp),
      'scanHelpSha256': _sha256(scanHelp),
      'terminalScanSha256': _sha256(utf8.encode(terminal)),
      'jsonScanSha256': _sha256(utf8.encode(normalizedJson)),
      'htmlScanSha256': _sha256(utf8.encode(normalizedHtml)),
      'findings': findings,
      'cliOptionNames': optionNames.toList()..sort(),
      'reportSchemaKeys': schemaKeys.toList()..sort(),
    };
  } finally {
    staging.deleteVerified();
  }
}

void _copyDirectory(Directory source, Directory destination) {
  for (final entity in source.listSync(recursive: true, followLinks: false)) {
    final relative = p.relative(entity.path, from: source.path);
    final target = p.join(destination.path, relative);
    if (entity is Directory) {
      Directory(target).createSync(recursive: true);
    } else if (entity is File) {
      File(target).parent.createSync(recursive: true);
      entity.copySync(target);
    } else {
      throw StateError('unsupported fixture entity: ${entity.path}');
    }
  }
}

_CliResult _runCli(String repositoryRoot, List<String> arguments) {
  final result = Process.runSync(
    Platform.resolvedExecutable,
    ['run', 'bin/flutter_pruner.dart', ...arguments],
    workingDirectory: repositoryRoot,
    stdoutEncoding: null,
    stderrEncoding: utf8,
  );
  _require(
    result.exitCode == 0,
    'CLI ${arguments.join(' ')} failed: ${result.stderr}',
  );
  return _CliResult(Uint8List.fromList(result.stdout as List<int>));
}

void _removeTimingFields(Map<String, Object?> report) {
  final run = _jsonObject(report['run']);
  for (final key in const [
    'id',
    'startedAtUtc',
    'finishedAtUtc',
    'elapsedMicros',
  ]) {
    run.remove(key);
  }
  final execution = _jsonObject(report['execution']);
  for (final pass in _jsonObjectList(execution['analysisPasses'])) {
    pass.remove('elapsedMicros');
    for (final adapter in _jsonObjectList(pass['adapters'])) {
      adapter.remove('elapsedMicros');
    }
  }
}

String _normalizeHtml(String html, Map<String, Object?> normalizedReport) {
  final pattern = RegExp(
    r'(<script id="report-data" type="application/json">)(.*?)(</script>)',
    dotAll: true,
  );
  _require(pattern.hasMatch(html), 'HTML report data was not found');
  final escaped = _canonicalCompact(normalizedReport)
      .replaceAll('&', r'\u0026')
      .replaceAll('<', r'\u003c')
      .replaceAll('>', r'\u003e')
      .replaceAll('\u2028', r'\u2028')
      .replaceAll('\u2029', r'\u2029');
  return html.replaceFirstMapped(
    pattern,
    (match) => '${match.group(1)}$escaped${match.group(3)}',
  );
}

String _stripAnsi(String source) {
  return source.replaceAll(RegExp(r'\x1B\[[0-9;]*m'), '');
}

void _collectSchemaKeys(Object? value, String prefix, Set<String> output) {
  if (value is Map) {
    for (final rawEntry in value.entries) {
      final key = rawEntry.key as String;
      final next = prefix.isEmpty ? key : '$prefix.$key';
      output.add(next);
      _collectSchemaKeys(rawEntry.value, next, output);
    }
  } else if (value is List) {
    final next = '$prefix[]';
    output.add(next);
    for (final entry in value) {
      _collectSchemaKeys(entry, next, output);
    }
  }
}

void _validateCases(List<Map<String, Object?>> cases) {
  final ids = <String>{};
  final projectKeys = <String>{};
  for (final entry in cases) {
    final id = entry['canonicalNodeId'] as String;
    final projectKey = '${entry['project']}\u0000${entry['decodedKey']}';
    _require(ids.add(id), 'duplicate canonical node ID $id');
    _require(
      projectKeys.add(projectKey),
      'duplicate decoded project key $projectKey',
    );
    if (entry['truthLabel'] == 'mutation-negative') {
      _require(
        !entry.containsKey('expectedArbMembersByPath'),
        'negative case has mutation authority: $id',
      );
    }
  }
}

void _writeCanonicalJson(File file, Object? value) {
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(_canonicalize(value))}\n',
  );
}

String _canonicalCompact(Object? value) => jsonEncode(_canonicalize(value));

Object? _canonicalize(Object? value) {
  if (value is Map) {
    final result = SplayTreeMap<String, Object?>();
    for (final entry in value.entries) {
      result[entry.key as String] = _canonicalize(entry.value);
    }
    return result;
  }
  if (value is List) return value.map(_canonicalize).toList(growable: false);
  return value;
}

Map<String, Object?> _jsonObject(Object? value) {
  return (value as Map).cast<String, Object?>();
}

List<Map<String, Object?>> _jsonObjectList(Object? value) {
  return (value as List<Object?>).map(_jsonObject).toList(growable: false);
}

String _sha256(List<int> bytes) => sha256.convert(bytes).toString();

bool _bytesEqual(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

void _require(bool condition, String message) {
  if (!condition) throw StateError(message);
}

final class _PrivateStagingRoot {
  _PrivateStagingRoot._({
    required this.directory,
    required this.canonicalPath,
    required this.systemTempCanonicalPath,
    required this.marker,
    required this.markerToken,
    required this.normalizationIdentities,
  });

  static const _prefix = 'flutter_pruner_l10n_public_surface_';
  static const _markerName = '.flutter_pruner_staging_identity';

  final Directory directory;
  final String canonicalPath;
  final String systemTempCanonicalPath;
  final File marker;
  final String markerToken;
  final List<String> normalizationIdentities;

  static _PrivateStagingRoot create() {
    final systemTempCanonicalPath = Directory.systemTemp
        .resolveSymbolicLinksSync();
    final directory = Directory.systemTemp.createTempSync(_prefix);
    _require(
      FileSystemEntity.typeSync(directory.path, followLinks: false) ==
          FileSystemEntityType.directory,
      'private staging root is not a non-link directory',
    );
    final canonicalPath = directory.resolveSymbolicLinksSync();
    _require(
      p.dirname(canonicalPath) == systemTempCanonicalPath &&
          p.basename(canonicalPath).startsWith(_prefix),
      'private staging root identity is outside canonical system temp',
    );
    if (!Platform.isWindows) {
      _require(
        directory.statSync().mode & 0x3f == 0,
        'private staging root grants group or world permissions',
      );
    }

    final random = Random.secure();
    final markerToken = base64Url.encode(
      List<int>.generate(32, (_) => random.nextInt(256)),
    );
    final marker = File(p.join(directory.path, _markerName));
    marker.createSync(exclusive: true);
    final markerHandle = marker.openSync(mode: FileMode.writeOnly);
    try {
      markerHandle
        ..writeStringSync(markerToken)
        ..flushSync();
    } finally {
      markerHandle.closeSync();
    }
    _require(
      FileSystemEntity.typeSync(marker.path, followLinks: false) ==
              FileSystemEntityType.file &&
          marker.resolveSymbolicLinksSync() ==
              p.join(canonicalPath, _markerName),
      'private staging marker identity is uncertain',
    );

    final identities =
        <String>{
            directory.absolute.path,
            canonicalPath,
            Uri.file(directory.absolute.path).toString(),
            Uri.file(canonicalPath).toString(),
          }.where((value) => value.isNotEmpty).toList()
          ..sort((left, right) => right.length.compareTo(left.length));
    return _PrivateStagingRoot._(
      directory: directory,
      canonicalPath: canonicalPath,
      systemTempCanonicalPath: systemTempCanonicalPath,
      marker: marker,
      markerToken: markerToken,
      normalizationIdentities: identities,
    );
  }

  String normalize(String source) {
    var result = source;
    for (final identity in normalizationIdentities) {
      result = result.replaceAll(identity, _publicSurfaceStagingPlaceholder);
    }
    return result;
  }

  Object? normalizeObject(Object? value) {
    if (value is String) return normalize(value);
    if (value is Map) {
      return <String, Object?>{
        for (final entry in value.entries)
          entry.key as String: normalizeObject(entry.value),
      };
    }
    if (value is List) {
      return value.map(normalizeObject).toList(growable: false);
    }
    return value;
  }

  void requireNormalized(String source) {
    for (final identity in normalizationIdentities) {
      _require(
        !source.contains(identity),
        'public-surface output retained a private staging identity',
      );
    }
  }

  void deleteVerified() {
    _verifyIdentity();
    for (final entity in directory.listSync(
      recursive: true,
      followLinks: false,
    )) {
      final type = FileSystemEntity.typeSync(entity.path, followLinks: false);
      _require(
        type == FileSystemEntityType.file ||
            type == FileSystemEntityType.directory,
        'private staging cleanup rejected a link or uncertain entity type',
      );
      final resolved = entity.resolveSymbolicLinksSync();
      _require(
        p.isWithin(canonicalPath, resolved),
        'private staging cleanup entity escaped the created root',
      );
    }
    _verifyIdentity();
    directory.deleteSync(recursive: true);
    _require(
      FileSystemEntity.typeSync(directory.path, followLinks: false) ==
          FileSystemEntityType.notFound,
      'private staging cleanup did not remove the created root',
    );
  }

  void _verifyIdentity() {
    _require(
      FileSystemEntity.typeSync(directory.path, followLinks: false) ==
              FileSystemEntityType.directory &&
          directory.resolveSymbolicLinksSync() == canonicalPath &&
          p.dirname(canonicalPath) == systemTempCanonicalPath,
      'private staging root identity changed before cleanup',
    );
    _require(
      FileSystemEntity.typeSync(marker.path, followLinks: false) ==
              FileSystemEntityType.file &&
          marker.resolveSymbolicLinksSync() ==
              p.join(canonicalPath, _markerName) &&
          marker.readAsStringSync() == markerToken,
      'private staging marker changed before cleanup',
    );
  }
}

final class _FamilySpec {
  const _FamilySpec({
    required this.project,
    required this.revision,
    required this.packageRoot,
    required this.arbDirectory,
    required this.templateArb,
    required this.frameworkVersion,
  });

  final String project;
  final String revision;
  final String packageRoot;
  final String arbDirectory;
  final String templateArb;
  final String frameworkVersion;
}

final class _JsonMember {
  const _JsonMember(
    this.start,
    this.endExclusive,
    this.commaEnd,
    this.decodedKey,
  );

  final int start;
  final int endExclusive;
  final int? commaEnd;
  final String decodedKey;
}

final class _ByteCopy {
  const _ByteCopy(
    this.start,
    this.endExclusive,
    this.sourceStart,
    this.sourceEndExclusive,
  );

  final int start;
  final int endExclusive;
  final int sourceStart;
  final int sourceEndExclusive;
}

final class _ByteSpan {
  const _ByteSpan(this.start, this.endExclusive);

  final int start;
  final int endExclusive;
}

final class _NormalizationResult {
  const _NormalizationResult({
    required this.normalizedBytesByPath,
    required this.manifest,
  });

  final Map<String, Uint8List> normalizedBytesByPath;
  final Map<String, Object?> manifest;
}

final class _CliResult {
  const _CliResult(this.stdoutBytes);

  final Uint8List stdoutBytes;
}

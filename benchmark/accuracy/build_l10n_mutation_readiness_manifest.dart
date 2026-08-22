import 'dart:collection';
import 'dart:convert';
import 'dart:io';
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

const _families = <String, _FamilySpec>{
  'smooth': _FamilySpec(
    project: 'smooth',
    revision: 'bac71afd115f72e379c0b501b95e5ede20ecd636',
    packageRoot: 'packages/smooth_app',
    arbDirectory: 'packages/smooth_app/lib/l10n',
    templateArb: 'packages/smooth_app/lib/l10n/app_en.arb',
    frameworkVersion: '3.38.7',
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

Future<void> main(List<String> arguments) async {
  final options = _parseArguments(arguments);
  final evidenceRoot = Directory(options['evidence-root']!);
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
          : _gitBlob(repository, spec.revision, relativePath);
      arbObjects[relativePath] = _jsonObject(jsonDecode(utf8.decode(bytes)));
    }
    final template = arbObjects[spec.templateArb]!;
    final cases = _jsonObjectList(oracleDocuments[project]!['cases']);
    for (final sourceCase in cases) {
      final id = sourceCase['id'];
      final key = sourceCase['detailValue'];
      final label = sourceCase['label'];
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
    positiveCount == 378,
    'positive denominator drifted to $positiveCount',
  );
  _require(
    negativeCount == 2224,
    'negative denominator drifted to $negativeCount',
  );

  final manifest = <String, Object?>{
    'schemaVersion': 1,
    'oracleVersion': 'l10n-mutation-readiness-v1',
    'sourceOracles': sourceOracles,
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
    File(p.join(outputDirectory.path, 'gsy-normalized-family-v1.json')),
    gsyNormalization.manifest,
  );
  _writeCanonicalJson(
    File(p.join(outputDirectory.path, 'l10n-mutation-readiness-v1.json')),
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
    final lastIndexByKey = <String, int>{};
    for (var index = 0; index < originalMembers.length; index++) {
      lastIndexByKey[originalMembers[index].decodedKey] = index;
    }
    final removed = <_ByteSpan>[];
    for (var index = 0; index < originalMembers.length; index++) {
      final member = originalMembers[index];
      if (lastIndexByKey[member.decodedKey] != index) {
        _require(
          member.commaEnd != null,
          'duplicate final member in $relativePath',
        );
        removed.add(_ByteSpan(member.start, member.commaEnd!));
      }
    }
    removed.sort((left, right) => left.start.compareTo(right.start));
    for (var index = 1; index < removed.length; index++) {
      _require(
        removed[index - 1].endExclusive <= removed[index].start,
        'overlapping normalization spans in $relativePath',
      );
    }
    final replacement = _removeSpans(original, removed);
    final replacementMembers = _scanTopLevelMembers(replacement);
    final replacementKeys = <String>{};
    for (final member in replacementMembers) {
      _require(
        replacementKeys.add(member.decodedKey),
        'duplicate decoded key remains in $relativePath',
      );
    }
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
      'schemaVersion': 1,
      'normalizationVersion': 'gsy-normalized-family-v1',
      'repositorySha': spec.revision,
      'policy': 'retain-last-effective-decoded-top-level-member',
      'changedArbs': changedArbs,
    },
  );
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
    members.add(_JsonMember(start, commaEnd, decodedKey));
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

Uint8List _removeSpans(List<int> source, List<_ByteSpan> spans) {
  final builder = BytesBuilder(copy: false);
  var cursor = 0;
  for (final span in spans) {
    builder.add(source.sublist(cursor, span.start));
    cursor = span.endExclusive;
  }
  builder.add(source.sublist(cursor));
  return builder.takeBytes();
}

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
  List<String> arbPaths,
  Map<String, Object?>? gitjournalToolchain,
) {
  final toolchain =
      gitjournalToolchain ?? _fvmToolchainSelectionEvidence(repository, spec);
  final policy = <Map<String, Object?>>[];
  if (spec.project == 'smooth') {
    policy.add({
      'workingDirectory': '.',
      'executable': {
        'kind': 'flutterByVersion',
        'version': spec.frameworkVersion,
      },
      'arguments': [
        'analyze',
        '--no-pub',
        '--fatal-infos',
        '--fatal-warnings',
        '.',
      ],
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
      policy.add({
        'workingDirectory': spec.packageRoot,
        'executable': {
          'kind': 'flutterByVersion',
          'version': spec.frameworkVersion,
        },
        'arguments': [command, '--no-pub'],
      });
    }
  }
  final fixtureOverlays = switch (spec.project) {
    'gsy' => <Map<String, Object?>>[
      {
        'relativePath': 'lib/common/config/ignoreConfig.dart',
        'purpose': 'non-secret ignored configuration stub',
        'sha256':
            'cb2b8ad720d95f0f0c8e633c389a5ae0dc8876e274b7455d77bb6ed9350efbbe',
        'containsSecrets': false,
      },
    ],
    'gitjournal' => <Map<String, Object?>>[
      {
        'relativePath': 'lib/.env.dart',
        'purpose': 'non-secret environment stub',
        'sha256':
            'a4aee8e49b8ae44f874ae182b464cbba1d00ba3045eaf37c14d745849da98b33',
        'containsSecrets': false,
      },
    ],
    _ => <Map<String, Object?>>[],
  };
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
    'normalizationOverlays': spec.project == 'gsy'
        ? [
            {
              'manifest': 'gsy-normalized-family-v1.json',
              'policy': 'remove-declared-byte-spans',
            },
          ]
        : <Map<String, Object?>>[],
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
  final fixtureRoot = Directory('/tmp/flutter_pruner_l10n_public_surface_v1');
  _require(
    !fixtureRoot.existsSync(),
    'public-surface fixture path already exists',
  );
  fixtureRoot.createSync(recursive: true);
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

    final terminal = _stripAnsi(
      terminalFile.readAsStringSync(),
    ).replaceAll('\r\n', '\n');
    final report = _jsonObject(jsonDecode(jsonFile.readAsStringSync()));
    _removeTimingFields(report);
    final normalizedJson = _canonicalCompact(report);
    final normalizedHtml = _normalizeHtml(htmlFile.readAsStringSync(), report);
    final blockers = _jsonObject(report['blockers']);
    final findings = <Map<String, Object?>>[];
    for (final finding in _jsonObjectList(report['findings'])) {
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
    _collectSchemaKeys(report, '', schemaKeys);
    return {
      'fixture': 'test/fixtures/l10n_test',
      'captureBoundary': 'argv-only-child-process',
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
    fixtureRoot.deleteSync(recursive: true);
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
  const _JsonMember(this.start, this.commaEnd, this.decodedKey);

  final int start;
  final int? commaEnd;
  final String decodedKey;
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

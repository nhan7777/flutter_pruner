import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

const expectedOracleHashes = {
  'smooth': '3ba9fb5be7bb70dcb68856cf4339c3e80626d30844fbc93dd7c81ecf5cc99020',
  'gsy': '9e113537db5e2a7b057bffc0d1ff74ce6799c2b31b36b89ff36bcf3afda65d35',
  'gitjournal':
      'e07dafbb2b3cdecba0e928a08f0025ed8cc8bc161e0979dec73bb460b13ffc77',
};

const expectedNegativeReasons = {
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

void main() {
  test('freezes the independent l10n mutation-readiness oracle', () {
    final manifest = _readJson(
      'benchmark/accuracy/manifests/l10n-mutation-readiness-v1.json',
    );
    final normalization = _readJson(
      'benchmark/accuracy/manifests/gsy-normalized-family-v1.json',
    );

    expect(manifest['schemaVersion'], 1);
    expect(manifest['oracleVersion'], 'l10n-mutation-readiness-v1');
    expect(manifest['totals'], {
      'positiveKeys': 378,
      'negativeKeys': 2224,
      'families': 3,
      'individualMutationAttempts': 378,
      'familyMutationAttempts': 3,
      'requiredRestorations': 381,
    });

    final sourceOracles = _objectMap(manifest['sourceOracles']);
    expect(
      sourceOracles.map(
        (project, value) => MapEntry(project, _objectMap(value)['sha256']),
      ),
      expectedOracleHashes,
    );

    final families = _objectList(manifest['families']);
    final familiesByProject = {
      for (final family in families) family['project'] as String: family,
    };
    expect(familiesByProject.keys.toList()..sort(), [
      'gitjournal',
      'gsy',
      'smooth',
    ]);
    expect(
      familiesByProject.map(
        (project, family) => MapEntry(project, family['repositorySha']),
      ),
      {
        'smooth': 'bac71afd115f72e379c0b501b95e5ede20ecd636',
        'gsy': '2b6c49008afc44b90fee869dedf8e59a86482953',
        'gitjournal': 'c8a67e098db06335762f822d7733c330f4bd0d6b',
      },
    );
    expect(
      familiesByProject.map(
        (project, family) => MapEntry(project, family['packageRoot']),
      ),
      {'smooth': 'packages/smooth_app', 'gsy': '.', 'gitjournal': '.'},
    );

    final cases = _objectList(manifest['cases']);
    final projectCounts = <String, Map<String, int>>{};
    for (final project in familiesByProject.keys) {
      final projectCases = cases.where((entry) => entry['project'] == project);
      projectCounts[project] = {
        'positive': projectCases
            .where((entry) => entry['truthLabel'] == 'mutation-positive')
            .length,
        'negative': projectCases
            .where((entry) => entry['truthLabel'] == 'mutation-negative')
            .length,
      };
    }
    expect(projectCounts, {
      'smooth': {'positive': 323, 'negative': 1457},
      'gsy': {'positive': 17, 'negative': 386},
      'gitjournal': {'positive': 38, 'negative': 381},
    });

    final toolchainVersions = familiesByProject.map(
      (project, family) => MapEntry(
        project,
        _objectMap(family['toolchainSelectionEvidence'])['frameworkVersion'],
      ),
    );
    expect(toolchainVersions, {
      'smooth': '3.38.7',
      'gsy': '3.44.1',
      'gitjournal': '3.41.5',
    });
    expect(
      familiesByProject.map(
        (project, family) => MapEntry(
          project,
          _objectMap(family['toolchainSelectionEvidence'])['evidenceSha256'],
        ),
      )..remove('gitjournal'),
      {
        'smooth':
            'd7136e4315d88a5039d89d5e9b22743883e2c0fca30b26337b462acb7d1e65f3',
        'gsy':
            '6829953e403e4e06af06fadc4e33258c78a09fe460a3625835116c31cf4e20a9',
      },
    );

    for (final family in families) {
      expect(family['expectedConfigurationStatus'], 'supported');
      expect(family['expectedFamilyBatchStatus'], 'accepted');
      expect(family['repositorySha'], matches(RegExp(r'^[0-9a-f]{40}$')));
      expect(family['packageRoot'], isNotEmpty);
      expect(
        _objectMap(family['toolchainSelectionEvidence']),
        contains('frameworkVersion'),
      );
      expect(_objectList(family['verificationPolicy']), isNotEmpty);
      expect(
        _objectList(family['fixtureOverlays']),
        everyElement(isA<Map<String, Object?>>()),
      );
      expect(
        _objectList(family['normalizationOverlays']),
        everyElement(isA<Map<String, Object?>>()),
      );
    }

    expect(
      familiesByProject.map(
        (project, family) => MapEntry(project, family['verificationPolicy']),
      ),
      {
        'smooth': [
          {
            'workingDirectory': '.',
            'executable': {'kind': 'flutterByVersion', 'version': '3.38.7'},
            'arguments': [
              'analyze',
              '--no-pub',
              '--fatal-infos',
              '--fatal-warnings',
              '.',
            ],
          },
          {
            'workingDirectory': 'packages/smooth_app',
            'executable': {'kind': 'flutterByVersion', 'version': '3.38.7'},
            'arguments': ['test', '--no-pub'],
          },
        ],
        'gsy': [
          {
            'workingDirectory': '.',
            'executable': {'kind': 'flutterByVersion', 'version': '3.44.1'},
            'arguments': ['analyze', '--no-pub'],
          },
          {
            'workingDirectory': '.',
            'executable': {'kind': 'flutterByVersion', 'version': '3.44.1'},
            'arguments': ['test', '--no-pub'],
          },
        ],
        'gitjournal': [
          {
            'workingDirectory': '.',
            'executable': {'kind': 'flutterByVersion', 'version': '3.41.5'},
            'arguments': ['analyze', '--no-pub'],
          },
          {
            'workingDirectory': '.',
            'executable': {'kind': 'flutterByVersion', 'version': '3.41.5'},
            'arguments': ['test', '--no-pub'],
          },
        ],
      },
    );

    final gitjournalToolchain = _objectMap(
      familiesByProject['gitjournal']!['toolchainSelectionEvidence'],
    );
    expect(gitjournalToolchain, {
      'frameworkVersion': '3.41.5',
      'frameworkRevision': '2c9eb20739dfec95e2c74bd3dfa4601b0a8a36aa',
      'engineRevision': '052f31d115eceda8cbff1b3481fcde4330c4ae12',
      'bundledDartVersion': '3.11.3',
      'ciResolutionEvidenceSha256':
          '4980a6207c2caa7a0f65cbc7b1390eb1fffe18f3dad3e7bb0b072cf033dd94d3',
      'probeArgv': ['flutter', '--version', '--machine'],
      'boundedProbeOutputSha256':
          'f1635a2a13f5ca240c48dc4fb8e0fab82758ce6aedeb66a3664af7d38844989c',
    });

    expect(manifest['mutationNegativeFixtures'], expectedNegativeReasons);

    final canonicalNodeIds = <String>{};
    final projectKeys = <String>{};
    for (final entry in cases) {
      final canonicalNodeId = entry['canonicalNodeId'];
      final project = entry['project'];
      final decodedKey = entry['decodedKey'];
      expect(canonicalNodeId, isA<String>());
      expect(canonicalNodeId, isNotEmpty);
      expect(canonicalNodeIds.add(canonicalNodeId as String), isTrue);
      expect(decodedKey, isA<String>());
      expect(decodedKey, isNotEmpty);
      expect(projectKeys.add('$project\u0000$decodedKey'), isTrue);
      expect(
        entry['truthLabel'],
        isIn(['mutation-positive', 'mutation-negative']),
      );
      expect(entry['expectedScannerPresence'], isA<bool>());

      if (entry['truthLabel'] == 'mutation-positive') {
        final membersByPath = _objectMap(entry['expectedArbMembersByPath']);
        expect(membersByPath, isNotEmpty);
        final paths = membersByPath.keys.toList();
        expect(paths, orderedEquals([...paths]..sort()));
        for (final members in membersByPath.values) {
          final names = (members as List<Object?>).cast<String>();
          expect(names, isNotEmpty);
          expect(names, orderedEquals([...names]..sort()));
          expect(names, contains(decodedKey));
        }
      } else {
        expect(entry, isNot(contains('expectedArbMembersByPath')));
      }
    }

    final publicSurface = _objectMap(manifest['publicSurfaceBaseline']);
    expect(publicSurface['timingFieldsRemoved'], [
      'execution.analysisPasses[].adapters[].elapsedMicros',
      'execution.analysisPasses[].elapsedMicros',
      'run.elapsedMicros',
      'run.finishedAtUtc',
      'run.id',
      'run.startedAtUtc',
    ]);
    expect(publicSurface['topLevelHelpSha256'], matches(_sha256));
    expect(publicSurface['scanHelpSha256'], matches(_sha256));
    expect(publicSurface['terminalScanSha256'], matches(_sha256));
    expect(publicSurface['jsonScanSha256'], matches(_sha256));
    expect(publicSurface['htmlScanSha256'], matches(_sha256));
    final baselineFindings = _objectList(publicSurface['findings']);
    expect(baselineFindings, isNotEmpty);
    final baselineFindingIds = baselineFindings
        .map((finding) => finding['id'] as String)
        .toList();
    expect(baselineFindingIds, orderedEquals([...baselineFindingIds]..sort()));
    for (final finding in baselineFindings) {
      expect(
        finding.keys,
        containsAll(const [
          'id',
          'tier',
          'classificationReasons',
          'blockerIdentities',
        ]),
      );
    }
    final optionNames = _stringList(publicSurface['cliOptionNames']);
    expect(optionNames, isNotEmpty);
    expect(optionNames, orderedEquals([...optionNames]..sort()));
    final reportSchemaKeys = _stringList(publicSurface['reportSchemaKeys']);
    expect(reportSchemaKeys, isNotEmpty);
    expect(reportSchemaKeys, orderedEquals([...reportSchemaKeys]..sort()));

    expect(normalization['schemaVersion'], 1);
    expect(normalization['normalizationVersion'], 'gsy-normalized-family-v1');
    expect(
      normalization['repositorySha'],
      '2b6c49008afc44b90fee869dedf8e59a86482953',
    );
    final changedArbs = _objectList(normalization['changedArbs']);
    expect(changedArbs.map((arb) => arb['relativePath']), [
      'lib/common/localization/l10n/app_en.arb',
      'lib/common/localization/l10n/app_ja.arb',
      'lib/common/localization/l10n/app_ko.arb',
      'lib/common/localization/l10n/app_zh.arb',
    ]);
    for (final arb in changedArbs) {
      expect(arb['relativePath'], endsWith('.arb'));
      expect(arb['originalSha256'], matches(_sha256));
      expect(arb['replacementSha256'], matches(_sha256));
      expect(arb['canonicalDecodedObjectSha256'], matches(_sha256));
      final spans = _objectList(arb['removedByteSpans']);
      expect(spans, isNotEmpty);
      var previousEnd = -1;
      for (final span in spans) {
        final start = span['start'] as int;
        final end = span['endExclusive'] as int;
        expect(start, greaterThanOrEqualTo(previousEnd));
        expect(end, greaterThan(start));
        previousEnd = end;
      }
      expect(arb['decodedObjectEquivalent'], isTrue);
      expect(arb['replacementHasDuplicateDecodedKeys'], isFalse);
    }
    expect(normalization, isNot(contains('thirdPartySourceBytes')));
  });
}

final _sha256 = RegExp(r'^[0-9a-f]{64}$');

Map<String, Object?> _readJson(String path) {
  return (jsonDecode(File(path).readAsStringSync()) as Map)
      .cast<String, Object?>();
}

Map<String, Object?> _objectMap(Object? value) {
  return (value as Map).cast<String, Object?>();
}

List<Map<String, Object?>> _objectList(Object? value) {
  return (value as List<Object?>)
      .map((entry) => _objectMap(entry))
      .toList(growable: false);
}

List<String> _stringList(Object? value) {
  return (value as List<Object?>).cast<String>();
}

import 'package:flutter_pruner/src/cli/formatters/human_formatter.dart';
import 'package:flutter_pruner/src/core/confidence/classification_reason.dart';
import 'package:flutter_pruner/src/core/confidence/confidence.dart';
import 'package:flutter_pruner/src/core/confidence/finding.dart';
import 'package:flutter_pruner/src/core/graph/build_condition.dart';
import 'package:flutter_pruner/src/core/graph/evidence.dart';
import 'package:flutter_pruner/src/core/graph/node.dart';
import 'package:flutter_pruner/src/core/project/analysis_mode.dart';
import 'package:flutter_pruner/src/core/project/target_matrix.dart';
import 'package:flutter_pruner/src/reporting/run_report.dart';
import 'package:test/test.dart';

void main() {
  group('HumanFormatter', () {
    test('renders four colored lanes in action-first order', () {
      final output = const HumanFormatter(lineWidth: 200).format(
        _report([
          _finding(Confidence.protected, 'protected.dart'),
          _finding(Confidence.review, 'review.dart'),
          _finding(Confidence.high, 'high.dart'),
          _finding(Confidence.safe, 'safe.dart'),
        ]),
      );

      expect(output, contains('\x1B[32m'));
      expect(output, contains('\x1B[33m'));
      expect(output, contains('\x1B[36m'));
      expect(output, contains('\x1B[35m'));

      final plain = _stripAnsi(output);
      final headers = plain
          .split('\n')
          .firstWhere(
            (line) =>
                line.contains('SAFE (1)') &&
                line.contains('HIGH (1)') &&
                line.contains('REVIEW (1)') &&
                line.contains('PROTECTED (1)'),
          );
      expect(headers.indexOf('SAFE'), lessThan(headers.indexOf('HIGH')));
      expect(headers.indexOf('HIGH'), lessThan(headers.indexOf('REVIEW')));
      expect(headers.indexOf('REVIEW'), lessThan(headers.indexOf('PROTECTED')));

      final board = plain.substring(plain.indexOf('FINDINGS'));
      expect(
        board.split('\n').where((line) => line.isNotEmpty),
        everyElement(predicate<String>((line) => line.runes.length <= 200)),
      );
    });

    test('falls back to two lanes and then one lane as width shrinks', () {
      final findings = [
        _finding(Confidence.safe, 'safe.dart'),
        _finding(Confidence.high, 'high.dart'),
        _finding(Confidence.review, 'review.dart'),
        _finding(Confidence.protected, 'protected.dart'),
      ];

      final twoLaneLines = _stripAnsi(
        const HumanFormatter(lineWidth: 160).format(_report(findings)),
      ).split('\n');
      expect(
        twoLaneLines,
        contains(
          predicate<String>(
            (line) => line.contains('SAFE (1)') && line.contains('HIGH (1)'),
          ),
        ),
      );
      expect(
        twoLaneLines,
        contains(
          predicate<String>(
            (line) =>
                line.contains('REVIEW (1)') && line.contains('PROTECTED (1)'),
          ),
        ),
      );

      final oneLaneLines = _stripAnsi(
        const HumanFormatter(lineWidth: 80).format(_report(findings)),
      ).split('\n');
      final safeHeader = oneLaneLines.firstWhere(
        (line) => line.contains('SAFE (1)'),
      );
      expect(safeHeader, isNot(contains('HIGH (1)')));

      final compact = _stripAnsi(
        const HumanFormatter(lineWidth: 50).format(_report(findings)),
      );
      final compactBoard = compact.substring(compact.indexOf('FINDINGS'));
      expect(compactBoard, isNot(contains('┌')));
      expect(
        compactBoard.split('\n').where((line) => line.isNotEmpty),
        everyElement(predicate<String>((line) => line.runes.length <= 50)),
      );
    });

    test('uses project-relative segment-aware middle trimming', () {
      final review = _finding(
        Confidence.review,
        'review.dart',
        blockerLocation:
            '/project/lib/src/features/order_confirm/presentation/views/'
            'order_confirm_wrapper_page.dart:264:67',
      );

      final plain = _stripAnsi(
        const HumanFormatter(lineWidth: 400).format(_report([review])),
      );

      expect(
        plain,
        contains('lib/src/.../views/order_confirm_wrapper_page.dart:264:67'),
      );
      expect(plain, isNot(contains('/project/lib/src/features')));
    });

    test('highlights a written report after findings and diagnostics', () {
      const path =
          '/Users/nhan/Desktop/project/LongChau/packages/khlc-product/'
          '.flutter_pruner/reports/scan-report.html';
      final output = const HumanFormatter(
        lineWidth: 60,
        reportPath: path,
        reportFormat: 'html',
      ).format(_report([_finding(Confidence.review, 'review.dart')]));
      final plain = _stripAnsi(output);

      expect(plain, contains('HTML REPORT READY'));
      expect(output.split('\n'), contains(path));
      expect(plain.split('\n'), contains(path));
      expect(
        plain.indexOf('HTML REPORT READY'),
        greaterThan(plain.indexOf('SCAN COMPLETED')),
      );
      expect(
        plain.indexOf('HTML REPORT READY'),
        greaterThan(plain.indexOf('FINDINGS')),
      );
    });

    test('highlights a written report after a zero-finding verbose report', () {
      final plain = _stripAnsi(
        const HumanFormatter(
          verbose: true,
          reportPath: '/project/.flutter_pruner/reports/scan.json',
          reportFormat: 'json',
        ).format(_report(const [])),
      );

      expect(plain, contains('No unused candidates found'));
      expect(plain, contains('DIAGNOSTICS'));
      expect(
        plain.indexOf('JSON REPORT READY'),
        greaterThan(plain.indexOf('DIAGNOSTICS')),
      );
      expect(
        plain.trimRight(),
        endsWith('/project/.flutter_pruner/reports/scan.json'),
      );
    });

    test('omits irrelevant unknown bytes and explains reasons plainly', () {
      final output = _stripAnsi(
        const HumanFormatter(lineWidth: 400).format(
          _report([
            _finding(
              Confidence.review,
              'missing_targets.dart',
              sourceBytes: null,
              classificationReasons: const [
                ClassificationReason.incompleteTargetMatrix,
              ],
            ),
            _finding(
              Confidence.review,
              'unknown_asset.png',
              sourceBytes: null,
              kind: NodeKind.asset,
              adapter: 'assets',
            ),
          ]),
        ),
      );

      expect(output, isNot(contains('dart · unknown bytes')));
      expect(
        output,
        contains('Missing targets in .flutter_pruner/config.yaml'),
      );
      expect(output, isNot(contains('incomplete-target-matrix')));
      expect(output, contains('Asset · size unavailable'));
    });

    test('shows decision summary and friendly impact without diagnostics', () {
      final output = _stripAnsi(
        const HumanFormatter(lineWidth: 160).format(
          _report(
            [
              _finding(Confidence.safe, 'safe.dart'),
              _finding(Confidence.review, 'review.dart'),
            ],
            blockerStatistics: BlockerStatistics(
              recorded: 136,
              activeUnique: 5,
              affectedFindings: 1,
              byProducer: {'dart': 5},
            ),
            measurements: const [
              RunMeasurement(
                kind: 'asset-family-source-bytes',
                status: MeasurementStatus.measured,
                unit: 'bytes',
                value: 1677722,
                scope: 'assets-inventory',
                aggregation: 'unique-asset-family-paths',
              ),
              RunMeasurement(
                kind: 'duplicate-potential-reclaimable-bytes',
                status: MeasurementStatus.measured,
                unit: 'bytes',
                value: 6758,
                scope: 'duplicate-inventory',
                aggregation: 'within-duplicate-groups-only',
              ),
              RunMeasurement(
                kind: 'dart-finding-source-bytes',
                status: MeasurementStatus.unknown,
                unit: 'bytes',
                scope: 'dart-findings',
                aggregation: 'not-additive-with-file-inventory',
              ),
            ],
          ),
        ),
      );

      expect(output, contains('✓ SCAN COMPLETED · 2 findings'));
      expect(output, contains('1 ready to preview'));
      expect(output, contains('1 need inspection'));
      expect(output, contains('Up to 6.6 KiB reclaimable'));
      expect(output, contains('1.6 MiB scanned'));
      expect(output, contains('Inventory only · not estimated savings'));
      expect(
        output,
        contains('1 finding affected · manual inspection required'),
      );
      expect(output, contains('flutter_pruner apply --dry-run'));
      expect(output, isNot(contains('dart-finding-source-bytes')));
      expect(output, isNot(contains('136 recorded')));
      expect(output, isNot(contains('policy v1')));
    });

    test('warns clearly when graph coverage is incomplete', () {
      final output = const HumanFormatter().format(
        _report(const [], danglingEdges: 1),
      );

      expect(
        _stripAnsi(output),
        contains('⚠ SCAN COMPLETED WITH WARNINGS · 0 findings'),
      );
      expect(
        _stripAnsi(output),
        contains('1 unresolved reference · results downgraded'),
      );
      expect(
        _stripAnsi(output),
        contains('No findings reported. Results may be incomplete'),
      );
      expect(_stripAnsi(output), isNot(contains('No unused candidates found')));
    });

    test('warns and suppresses clean guidance for dangling roots', () {
      final output = _stripAnsi(
        const HumanFormatter().format(_report(const [], danglingRoots: 1)),
      );

      expect(output, contains('⚠ SCAN COMPLETED WITH WARNINGS · 0 findings'));
      expect(output, contains('1 unresolved root · results downgraded'));
      expect(output, contains('Configured roots point to unregistered nodes'));
      expect(output, isNot(contains('No unused candidates found')));
    });

    test(
      'explains incomplete target coverage and suppresses apply guidance',
      () {
        final output = _stripAnsi(
          const HumanFormatter().format(
            _report([
              _finding(Confidence.review, 'review.dart'),
            ], targetMatrixComplete: false),
          ),
        );

        expect(output, contains('Incomplete · SAFE/HIGH disabled'));
        expect(
          output,
          contains('Add every supported platform, flavor and entrypoint'),
        );
        expect(output, contains('Run flutter_pruner init'));
        expect(output, isNot(contains('flutter_pruner apply --dry-run')));
      },
    );

    test('explains that reusable packages remain audit-only', () {
      final output = _stripAnsi(
        const HumanFormatter().format(
          _report(
            [_finding(Confidence.review, 'review.dart')],
            targetMatrixComplete: false,
            rootCoverage: RootCoverage(
              mode: RootCoverageMode.packagePublicApi,
              internalBoundaryComplete: true,
              externalConsumersCovered: false,
              source: '/project/.flutter_pruner/config.yaml',
              publicEntrypoints: ['lib/test.dart'],
              issues: [
                'package consumers are open-world in this version; complete '
                    'workspace consumer roots are not implemented',
              ],
            ),
            analysisMode: AnalysisMode.package,
          ),
        ),
      );

      expect(output, contains('Consumers'));
      expect(output, contains('Open world · audit only'));
      expect(output, contains('Reusable packages may have external consumers'));
      expect(output, contains('do not apply them automatically'));
      expect(output, isNot(contains('then confirm coverage')));
    });

    test('verbose output includes complete findings and diagnostics', () {
      final findings = [
        for (var index = 0; index < 7; index++)
          _finding(Confidence.safe, 'safe_$index.dart'),
      ];
      final regular = _stripAnsi(
        const HumanFormatter(lineWidth: 200).format(_report(findings)),
      );
      final verbose = _stripAnsi(
        const HumanFormatter(
          verbose: true,
          lineWidth: 200,
        ).format(_report(findings)),
      );

      expect(regular, contains('... +1 more'));
      expect(regular, isNot(contains('DIAGNOSTICS')));
      expect(verbose, isNot(contains('... +1 more')));
      expect(verbose, contains('safe_6.dart'));
      expect(verbose, contains('DIAGNOSTICS'));
      expect(verbose, contains('Run: run-test'));
      expect(verbose, contains('Measurements (rows are not additive)'));
    });
  });
}

Finding _finding(
  Confidence confidence,
  String fileName, {
  String? blockerLocation,
  int? sourceBytes = 4096,
  NodeKind kind = NodeKind.declaration,
  String adapter = 'dart',
  List<ClassificationReason>? classificationReasons,
}) {
  final blocker = blockerLocation == null
      ? null
      : Blocker(
          producer: 'dart',
          reason: 'dynamic reference',
          location: blockerLocation,
        );
  return Finding(
    ruleId: 'PRN-DART-001',
    node: GraphNode(
      id: 'dart:test/lib/src/$fileName#symbol',
      kind: kind,
      origin: Uri.file('/project/lib/src/$fileName'),
      displayName: fileName.replaceAll('.dart', ''),
      sizeBytes: sourceBytes,
    ),
    confidence: confidence,
    title: fileName,
    predicates: SafetyPredicates(
      ruleAllowsAutoFix: true,
      unreachableAcrossAllTargets: true,
      noDynamicBlockers: confidence != Confidence.review,
      notProtected: confidence != Confidence.protected,
      noPublicApiRisk: confidence != Confidence.high,
      hasDeterministicInverse: true,
    ),
    blockers: blocker == null ? const [] : [blocker],
    protectionReasons: confidence == Confidence.protected
        ? const ['framework entry point']
        : const [],
    proposedAction:
        confidence == Confidence.safe || confidence == Confidence.high
        ? 'Remove declaration'
        : null,
    sourceBytes: sourceBytes,
    classificationReasons:
        classificationReasons ??
        (confidence == Confidence.high
            ? const [ClassificationReason.externalConsumersNotScanned]
            : const []),
    reportingAdapterId: adapter,
  );
}

RunReport _report(
  List<Finding> findings, {
  int danglingEdges = 0,
  int danglingRoots = 0,
  BlockerStatistics? blockerStatistics,
  List<RunMeasurement> measurements = const [],
  bool targetMatrixComplete = true,
  AnalysisMode analysisMode = AnalysisMode.application,
  RootCoverage? rootCoverage,
}) {
  final statistics = FindingStatistics.fromFindings(findings);
  final pass = AnalysisPassReport(
    id: 'analysis-001',
    purpose: AnalysisPassPurpose.initial,
    elapsedMicros: 10,
    nodeCount: findings.length,
    edgeCount: 0,
    rootCount: 1,
    recordedBlockerCount: 0,
    danglingEdgeCount: danglingEdges,
    danglingRootCount: danglingRoots,
    adapterRuns: const [],
    findingStatistics: statistics,
    blockerStatistics:
        blockerStatistics ??
        BlockerStatistics(
          recorded: 0,
          activeUnique: 0,
          affectedFindings: 0,
          byProducer: const {},
        ),
    measurements: measurements,
    exclusionPolicyVersion: 1,
    exclusionsByReason: const {},
  );
  return RunReport(
    identity: RunIdentity(
      id: 'run-test',
      command: RunCommand.scan,
      toolVersion: 'test',
      startedAtUtc: DateTime.utc(2026, 8, 14),
      finishedAtUtc: DateTime.utc(2026, 8, 14, 0, 0, 1),
      elapsedMicros: 1000000,
    ),
    status: RunStatus.completed,
    exitCode: 0,
    partialApplied: false,
    projectRoot: '/project',
    packageName: 'test',
    analysisMode: analysisMode,
    requestedAdapters: const ['dart'],
    targetMatrix: TargetMatrix(
      targets: [
        BuildTarget(
          name: 'android',
          platform: 'android',
          entrypoint: 'lib/main.dart',
        ),
      ],
      status: targetMatrixComplete
          ? TargetMatrixStatus.declaredComplete
          : TargetMatrixStatus.declaredPartial,
      source: '/project/flutter_pruner.yaml',
      issues: targetMatrixComplete
          ? const []
          : const ['the configuration declares a partial target matrix'],
    ),
    rootCoverage: rootCoverage ?? RootCoverage.applicationApi(),
    analysisPasses: [pass],
    findings: findings,
    diagnostics: const [],
  );
}

String _stripAnsi(String value) =>
    value.replaceAll(RegExp(r'\x1B\[[0-9;]*m'), '');

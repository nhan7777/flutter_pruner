import 'package:flutter_pruner/src/core/graph/build_condition.dart';
import 'package:flutter_pruner/src/core/graph/node.dart';
import 'package:flutter_pruner/src/core/graph/reachability_graph.dart';
import 'package:flutter_pruner/src/core/project/target_matrix.dart';
import 'package:test/test.dart';

void main() {
  test('snapshots targets and issues without changing coverage evidence', () {
    final target = BuildTarget(
      name: 'android-prod',
      platform: 'android',
      entrypoint: 'lib/main_prod.dart',
    );
    final targets = [target];
    final issues = ['owner review pending'];
    final matrix = TargetMatrix(
      targets: targets,
      status: TargetMatrixStatus.declaredComplete,
      source: 'test config',
      issues: issues,
    );

    targets.clear();
    issues
      ..clear()
      ..add('mutated issue');

    expect(matrix.isComplete, isTrue);
    expect(matrix.targets, [target]);
    expect(matrix.targets.single, isNot(same(target)));
    expect(matrix.issues, ['owner review pending']);
    expect(() => matrix.targets.clear(), throwsUnsupportedError);
    expect(() => matrix.issues.add('late issue'), throwsUnsupportedError);
  });

  test('declared factory snapshots targets and preserves their order', () {
    final android = BuildTarget(
      name: 'android',
      platform: 'android',
      entrypoint: 'lib/main.dart',
    );
    final web = BuildTarget(
      name: 'web',
      platform: 'web',
      entrypoint: 'lib/main_web.dart',
    );
    final targets = [android, web];
    final matrix = TargetMatrix.declared(targets);

    targets
      ..clear()
      ..addAll([web, android]);

    expect(matrix.targets, [android, web]);
    expect(matrix.targets.first, isNot(same(android)));
    expect(matrix.targets.last, isNot(same(web)));
    expect(matrix.isComplete, isTrue);
    expect(() => matrix.targets.add(android), throwsUnsupportedError);
  });

  test('snapshots immutable excluded application entrypoints', () {
    const exclusion = ExcludedApplicationEntrypoint(
      path: 'lib/guard.dart',
      reason: 'tracked launcher guard is not supported',
    );
    final exclusions = [exclusion];
    final matrix = TargetMatrix(
      targets: [
        BuildTarget(
          name: 'android',
          platform: 'android',
          entrypoint: 'lib/main.dart',
        ),
      ],
      status: TargetMatrixStatus.declaredComplete,
      source: 'test config',
      excludedEntrypoints: exclusions,
    );

    exclusions.clear();

    expect(matrix.excludedEntrypoints, [exclusion]);
    expect(() => matrix.excludedEntrypoints.clear(), throwsUnsupportedError);
  });

  test('rejects unsafe excluded application entrypoints', () {
    final target = BuildTarget(
      name: 'android',
      platform: 'android',
      entrypoint: 'lib/main.dart',
    );

    for (final exclusions in [
      const [
        ExcludedApplicationEntrypoint(path: 'lib/guard.dart', reason: '   '),
      ],
      const [
        ExcludedApplicationEntrypoint(path: 'lib/guard.dart', reason: 'first'),
        ExcludedApplicationEntrypoint(path: 'lib/guard.dart', reason: 'second'),
      ],
      const [
        ExcludedApplicationEntrypoint(path: 'lib/main.dart', reason: 'overlap'),
      ],
    ]) {
      expect(
        () => TargetMatrix(
          targets: [target],
          status: TargetMatrixStatus.declaredComplete,
          source: 'test config',
          excludedEntrypoints: exclusions,
        ),
        throwsArgumentError,
      );
    }

    expect(
      () => TargetMatrix(
        targets: [target],
        status: TargetMatrixStatus.declaredPartial,
        source: 'test config',
        excludedEntrypoints: const [
          ExcludedApplicationEntrypoint(
            path: 'lib/guard.dart',
            reason: 'owner evidence',
          ),
        ],
      ),
      throwsArgumentError,
    );
  });

  test('rejects configured names that derive the same context identity', () {
    final web = BuildTarget(
      name: 'web',
      platform: 'web',
      entrypoint: 'lib/main.dart',
    );
    final prefixedWeb = BuildTarget(
      name: 'app:web',
      platform: 'web',
      entrypoint: 'lib/main_staging.dart',
      flavor: 'staging',
      dartDefines: const {'ENV': 'staging'},
    );

    expect(
      () => TargetMatrix.declared([web, prefixedWeb]),
      throwsArgumentError,
    );
  });

  test('root coverage snapshots public entrypoints and issues', () {
    final publicEntrypoints = ['lib/app.dart'];
    final issues = ['owner evidence'];
    final coverage = RootCoverage(
      mode: RootCoverageMode.packageInternal,
      internalBoundaryComplete: true,
      externalConsumersCovered: true,
      source: 'test config',
      publicEntrypoints: publicEntrypoints,
      issues: issues,
    );

    publicEntrypoints.clear();
    issues
      ..clear()
      ..add('mutated issue');

    expect(coverage.complete, isTrue);
    expect(coverage.publicEntrypoints, ['lib/app.dart']);
    expect(coverage.issues, ['owner evidence']);
    expect(() => coverage.publicEntrypoints.clear(), throwsUnsupportedError);
    expect(() => coverage.issues.add('late issue'), throwsUnsupportedError);
  });

  test(
    'matrix target snapshots survive mutable caller targets in graph queries',
    () {
      final defines = <String, String>{'MODE': 'debug'};
      final mutable = _MutableBuildTarget(
        name: 'android-debug',
        platform: 'android',
        flavor: 'debug',
        entrypoint: 'lib/main.dart',
        dartDefines: defines,
      );
      final matrix = TargetMatrix.declared([mutable]);
      final graph = ReachabilityGraph()
        ..addNode(
          GraphNode(
            id: 'configured-root',
            kind: NodeKind.declaration,
            origin: Uri.file('/project/lib/main.dart'),
          ),
        )
        ..addRoot(
          'configured-root',
          reason: 'configured target root',
          condition: BuildCondition.forTarget(matrix.targets.single),
        );

      mutable
        ..name = 'android-release'
        ..flavor = 'release';
      defines['MODE'] = 'release';

      final frozenTarget = matrix.targets.single;
      expect(frozenTarget, isNot(same(mutable)));
      expect(frozenTarget.name, 'android-debug');
      expect(frozenTarget.flavor, 'debug');
      expect(frozenTarget.dartDefines, {'MODE': 'debug'});
      expect(graph.reachableFor(frozenTarget), {'configured-root'});
      expect(
        graph.unreachableAcrossAll(matrix.targets),
        isNot(contains('configured-root')),
      );
    },
  );
}

class _MutableBuildTarget implements BuildTarget {
  _MutableBuildTarget({
    required this.name,
    required this.platform,
    required this.flavor,
    required this.entrypoint,
    required this.dartDefines,
  });

  @override
  Map<String, String> dartDefines;

  @override
  String entrypoint;

  @override
  String? flavor;

  @override
  String name;

  @override
  String platform;
}

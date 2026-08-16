import 'package:flutter_pruner/src/core/graph/build_condition.dart';
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
    expect(matrix.targets, [same(target)]);
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

    expect(matrix.targets, [same(android), same(web)]);
    expect(matrix.isComplete, isTrue);
    expect(() => matrix.targets.add(android), throwsUnsupportedError);
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
}

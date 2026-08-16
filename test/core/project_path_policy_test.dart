import 'dart:io';

import 'package:flutter_pruner/src/core/project/project_path_policy.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('project_path_policy_test_');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('matches path segments without excluding similar legitimate names', () {
    final policy = ProjectPathPolicy(root: root);

    expect(
      policy.shouldExclude(p.join(root.path, '.codex', 'state.json')),
      isTrue,
    );
    expect(
      policy.shouldExclude(p.join(root.path, 'lib', 'build.dart')),
      isFalse,
    );
    expect(
      policy.shouldExclude(p.join(root.path, 'lib', 'my_build', 'a.dart')),
      isFalse,
    );
  });

  test('excludes dynamic report and quarantine paths', () {
    final report = p.join(root.path, 'reports', 'scan.json');
    final customQuarantine = p.join(root.path, 'tmp', 'pruner-backups');
    final policy = ProjectPathPolicy(
      root: root,
      additionalExcludedPaths: [report, customQuarantine],
    );

    expect(policy.shouldExclude(report), isTrue);
    expect(
      policy.shouldExclude(p.join(customQuarantine, 'run', 'manifest.json')),
      isTrue,
    );
    expect(
      policy.shouldExclude(p.join(root.path, 'reports', 'other.json')),
      isFalse,
    );
  });

  test('excludes every generated file below the tool workspace', () {
    final policy = ProjectPathPolicy(root: root);
    final report = p.join(root.path, '.flutter_pruner', 'reports', 'scan.json');

    expect(policy.shouldExclude(report), isTrue);
    expect(policy.snapshot().byReason['directory:.flutter_pruner'], 1);
  });

  test('distinguishes measured exclusions by reason', () {
    final policy = ProjectPathPolicy(root: root);

    policy.shouldExclude(p.join(root.path, '.agent', 'one'));
    policy.shouldExclude(p.join(root.path, '.agent', 'two'));
    policy.shouldExclude(p.join(root.path, '.agent', 'one'));

    expect(policy.snapshot().byReason['directory:.agent'], 2);
    policy.resetObservations();
    expect(policy.snapshot().total, 0);
  });
}

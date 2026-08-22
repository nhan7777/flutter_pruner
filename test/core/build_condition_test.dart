import 'package:flutter_pruner/flutter_pruner.dart';
import 'package:test/test.dart';

final BuildTarget _androidProd = BuildTarget(
  name: 'android-prod',
  platform: 'android',
  entrypoint: 'lib/main_prod.dart',
  flavor: 'prod',
  dartDefines: {'ENV': 'prod', 'ENABLE_BETA': 'false'},
);

final BuildTarget _plain = BuildTarget(
  name: 'plain',
  platform: 'android',
  entrypoint: 'lib/main.dart',
);

void main() {
  group('execution context identity', () {
    test('configured target names reject empty and control suffixes', () {
      for (final name in ['', 'web\nrelease', 'web\u007f']) {
        expect(
          () => BuildTarget(
            name: name,
            platform: 'web',
            entrypoint: 'lib/main.dart',
          ),
          throwsArgumentError,
          reason: 'invalid configured execution-context suffix: $name',
        );
      }
    });

    test('auxiliary IDs reject controls and nested context prefixes', () {
      for (final id in [
        'aux:test:',
        'aux:test:widget\ncase',
        'aux:test:app:web',
        'aux:test:aux:runtime:callback',
      ]) {
        expect(
          () => AuxiliaryExecutionTarget(
            id: id,
            domain: AuxiliaryExecutionDomain.test,
            environmentValues: const {},
            environmentComplete: true,
            reason: 'test',
          ),
          throwsArgumentError,
          reason: 'invalid auxiliary execution-context ID: $id',
        );
      }
    });

    test('auxiliary IDs preserve literal path hash and colon suffixes', () {
      for (final id in [
        'aux:test:test/widgets/scan_test.dart:vm',
        'aux:runtime:executable:tool/a_b.dart~0123456789abcdef:incomplete',
        'aux:external:lib/public_api.dart#Consumer.entry',
      ]) {
        final domain = id.startsWith('aux:test:')
            ? AuxiliaryExecutionDomain.test
            : id.startsWith('aux:runtime:')
            ? AuxiliaryExecutionDomain.runtime
            : AuxiliaryExecutionDomain.external;
        expect(
          AuxiliaryExecutionTarget(
            id: id,
            domain: domain,
            environmentValues: const {},
            environmentComplete: true,
            reason: 'test',
          ).id,
          id,
        );
      }
    });
  });

  group('unconditional', () {
    test('applies to every target', () {
      expect(BuildCondition.unconditional.isUnconditional, isTrue);
      expect(BuildCondition.unconditional.appliesTo(_androidProd), isTrue);
      expect(BuildCondition.unconditional.appliesTo(_plain), isTrue);
    });

    test('an empty condition is unconditional', () {
      expect(BuildCondition.unconditional.isUnconditional, isTrue);
    });

    test('any populated field makes it conditional', () {
      expect(BuildCondition(platforms: {'web'}).isUnconditional, isFalse);
      expect(BuildCondition(dartDefines: {'K': 'v'}).isUnconditional, isFalse);
    });
  });

  group('matching', () {
    test('platform must be in the set when the set is non-empty', () {
      final androidOnly = BuildCondition(platforms: {'android'});

      expect(androidOnly.appliesTo(_androidProd), isTrue);
      expect(
        androidOnly.appliesTo(
          BuildTarget(
            name: 'web',
            platform: 'web',
            entrypoint: 'lib/main.dart',
          ),
        ),
        isFalse,
      );
    });

    test('a multi-platform condition matches any member', () {
      final mobile = BuildCondition(platforms: {'android', 'ios'});

      expect(mobile.appliesTo(_androidProd), isTrue);
      expect(
        mobile.appliesTo(
          BuildTarget(
            name: 'ios',
            platform: 'ios',
            entrypoint: 'lib/main.dart',
          ),
        ),
        isTrue,
      );
    });

    test('flavor must match, and a null target flavor never matches', () {
      final prodOnly = BuildCondition(flavors: {'prod'});

      expect(prodOnly.appliesTo(_androidProd), isTrue);
      expect(prodOnly.appliesTo(_plain), isFalse);
    });

    test('entrypoint must match exactly', () {
      final prodEntry = BuildCondition(entrypoints: {'lib/main_prod.dart'});

      expect(prodEntry.appliesTo(_androidProd), isTrue);
      expect(prodEntry.appliesTo(_plain), isFalse);
    });

    test('every constraint must hold simultaneously', () {
      final both = BuildCondition(platforms: {'android'}, flavors: {'staging'});

      // Platform matches, flavor does not, so the whole condition fails.
      expect(both.appliesTo(_androidProd), isFalse);
    });
  });

  group('dart-defines', () {
    test('every required define must match the target', () {
      final needsProd = BuildCondition(dartDefines: {'ENV': 'prod'});

      expect(needsProd.appliesTo(_androidProd), isTrue);
      expect(needsProd.appliesTo(_plain), isFalse);
    });

    test('a value mismatch fails even when the key is present', () {
      // ENABLE_BETA is defined as 'false' on the target, so a condition
      // requiring 'true' must not apply. This is the const-folding case:
      // the guarded branch does not exist in that build.
      final needsBeta = BuildCondition(dartDefines: {'ENABLE_BETA': 'true'});

      expect(needsBeta.appliesTo(_androidProd), isFalse);
    });

    test('all required defines must match, not just one', () {
      final needsBoth = BuildCondition(
        dartDefines: {'ENV': 'prod', 'ENABLE_BETA': 'true'},
      );

      expect(needsBoth.appliesTo(_androidProd), isFalse);
    });

    test('a target may carry defines the condition does not mention', () {
      final needsEnv = BuildCondition(dartDefines: {'ENV': 'prod'});

      // Extra target defines are irrelevant; the condition only constrains
      // what it names.
      expect(needsEnv.appliesTo(_androidProd), isTrue);
    });

    test('target snapshots defines before later reachability passes', () {
      final defines = {'ENV': 'prod'};
      final target = BuildTarget(
        name: 'android-prod',
        platform: 'android',
        entrypoint: 'lib/main.dart',
        dartDefines: defines,
      );
      final graph = ReachabilityGraph()
        ..addNode(
          GraphNode(
            id: 'dart:app/lib/main.dart#main',
            kind: NodeKind.declaration,
            origin: Uri.file('/project/lib/main.dart'),
          ),
        )
        ..addRoot(
          'dart:app/lib/main.dart#main',
          reason: 'production entry point',
          condition: BuildCondition(dartDefines: {'ENV': 'prod'}),
        );

      final beforeMutation = graph.reachableFor(target);
      defines['ENV'] = 'dev';

      expect(beforeMutation, contains('dart:app/lib/main.dart#main'));
      expect(
        graph.reachableFor(target),
        contains('dart:app/lib/main.dart#main'),
      );
      expect(target.dartDefines, {'ENV': 'prod'});
      expect(
        () => target.dartDefines['ENV'] = 'staging',
        throwsUnsupportedError,
      );
    });
  });

  group('value semantics', () {
    test('build target equality includes its complete immutable tuple', () {
      final defines = <String, String>{'MODE': 'debug', 'REGION': 'vn'};
      final first = BuildTarget(
        name: 'android',
        platform: 'android',
        flavor: 'debug',
        entrypoint: 'lib/main.dart',
        dartDefines: defines,
      );
      final same = BuildTarget(
        name: 'android',
        platform: 'android',
        flavor: 'debug',
        entrypoint: 'lib/main.dart',
        dartDefines: <String, String>{'REGION': 'vn', 'MODE': 'debug'},
      );

      defines['MODE'] = 'release';

      expect(first, same);
      expect(first.hashCode, same.hashCode);
      expect(first.dartDefines, <String, String>{
        'MODE': 'debug',
        'REGION': 'vn',
      });
      expect(
        first,
        isNot(
          BuildTarget(
            name: 'android',
            platform: 'android',
            flavor: 'release',
            entrypoint: 'lib/main.dart',
            dartDefines: const {'MODE': 'debug', 'REGION': 'vn'},
          ),
        ),
      );
    });

    test('equal conditions compare equal and hash equal', () {
      final a = BuildCondition(
        platforms: {'android', 'ios'},
        dartDefines: {'ENV': 'prod'},
      );
      final b = BuildCondition(
        platforms: {'ios', 'android'},
        dartDefines: {'ENV': 'prod'},
      );

      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('differing defines are not equal', () {
      expect(
        BuildCondition(dartDefines: {'ENV': 'prod'}),
        isNot(equals(BuildCondition(dartDefines: {'ENV': 'dev'}))),
      );
    });

    test('toString is readable for reports', () {
      expect(BuildCondition.unconditional.toString(), 'BuildCondition(any)');
      expect(
        BuildCondition(platforms: {'web'}).toString(),
        contains('platforms'),
      );
    });

    test('toString does not depend on collection insertion order', () {
      final first = BuildCondition(
        platforms: {'web', 'android'},
        flavors: {'prod', 'debug'},
        entrypoints: {'lib/z.dart', 'lib/a.dart'},
        dartDefines: {'REGION': 'vn', 'MODE': 'debug'},
      );
      final second = BuildCondition(
        platforms: {'android', 'web'},
        flavors: {'debug', 'prod'},
        entrypoints: {'lib/a.dart', 'lib/z.dart'},
        dartDefines: {'MODE': 'debug', 'REGION': 'vn'},
      );

      expect(first.toString(), second.toString());
    });

    test('snapshots mutable collections before they can alter a hash key', () {
      final platforms = {'android'};
      final defines = {'ENV': 'prod'};
      final condition = BuildCondition(
        platforms: platforms,
        dartDefines: defines,
      );
      final conditions = {condition};

      platforms
        ..clear()
        ..add('web');
      defines['ENV'] = 'dev';

      expect(condition.platforms, {'android'});
      expect(condition.dartDefines, {'ENV': 'prod'});
      expect(conditions.contains(condition), isTrue);
      expect(() => condition.platforms.add('ios'), throwsUnsupportedError);
      expect(
        () => condition.dartDefines['ENV'] = 'staging',
        throwsUnsupportedError,
      );
    });
  });

  group('exact execution targets', () {
    final debug = BuildTarget(
      name: 'android-debug',
      platform: 'android',
      flavor: 'debug',
      entrypoint: 'lib/main.dart',
      dartDefines: const {'MODE': 'debug'},
    );
    final release = BuildTarget(
      name: 'android-release',
      platform: 'android',
      flavor: 'release',
      entrypoint: 'lib/main.dart',
      dartDefines: const {'MODE': 'release'},
    );
    final vmTest = AuxiliaryExecutionTarget(
      id: 'aux:test:vm-widget',
      domain: AuxiliaryExecutionDomain.test,
      environmentValues: const {'dart.library.io': 'true'},
      environmentComplete: true,
      reason: 'VM test runner',
    );

    test(
      'exact configured conditions do not collapse same-platform targets',
      () {
        final condition = BuildCondition.forTarget(debug);

        expect(condition.platforms, isEmpty);
        expect(condition.flavors, isEmpty);
        expect(condition.entrypoints, isEmpty);
        expect(condition.dartDefines, isEmpty);
        expect(condition.appliesTo(debug), isTrue);
        expect(condition.appliesTo(release), isFalse);
      },
    );

    test('one dart-define value difference does not match an exact target', () {
      final enabled = BuildTarget(
        name: 'android-debug',
        platform: 'android',
        flavor: 'debug',
        entrypoint: 'lib/main.dart',
        dartDefines: const {'MODE': 'debug', 'BETA': 'true'},
      );

      expect(BuildCondition.forTarget(debug).appliesTo(enabled), isFalse);
    });

    test('exact target membership snapshots caller-owned collections', () {
      final targets = <BuildTarget>{debug};
      final condition = BuildCondition(exactTargets: targets);

      targets
        ..clear()
        ..add(release);

      expect(condition.exactTargets, {debug});
      expect(condition.appliesTo(debug), isTrue);
      expect(condition.appliesTo(release), isFalse);
      expect(() => condition.exactTargets.add(release), throwsUnsupportedError);
    });

    test(
      'exact conditions canonicalize mutable BuildTarget implementations',
      () {
        final sourceDefines = <String, String>{'MODE': 'debug'};
        final mutable = _MutableBuildTarget(
          name: 'android-debug',
          platform: 'android',
          flavor: 'debug',
          entrypoint: 'lib/main.dart',
          dartDefines: sourceDefines,
        );
        final condition = BuildCondition.forTarget(mutable);
        final expected = BuildTarget(
          name: 'android-debug',
          platform: 'android',
          flavor: 'debug',
          entrypoint: 'lib/main.dart',
          dartDefines: const {'MODE': 'debug'},
        );
        final expectedCondition = BuildCondition.forTarget(expected);
        final hashBeforeMutation = condition.hashCode;
        final graph = ReachabilityGraph()
          ..addNode(
            GraphNode(
              id: 'mutable-root',
              kind: NodeKind.declaration,
              origin: Uri.file('/project/lib/main.dart'),
            ),
          )
          ..addRoot(
            'mutable-root',
            reason: 'mutable external target root',
            condition: condition,
          );

        expect(condition.appliesTo(mutable), isTrue);
        expect(graph.reachableFor(mutable), {'mutable-root'});

        mutable
          ..name = 'android-release'
          ..flavor = 'release';
        sourceDefines['MODE'] = 'release';

        expect(condition.exactTargets.single, isNot(same(mutable)));
        expect(condition.appliesTo(expected), isTrue);
        expect(condition.appliesTo(mutable), isFalse);
        expect(condition, expectedCondition);
        expect(condition.hashCode, hashBeforeMutation);
      },
    );

    test('auxiliary conditions snapshot their mutable source target', () {
      final sourceDefines = <String, String>{'MODE': 'debug'};
      final mutableSource = _MutableBuildTarget(
        name: 'android-debug',
        platform: 'android',
        flavor: 'debug',
        entrypoint: 'lib/main.dart',
        dartDefines: sourceDefines,
      );
      final auxiliary = AuxiliaryExecutionTarget(
        id: 'aux:test:vm-widget-source',
        domain: AuxiliaryExecutionDomain.test,
        environmentValues: const {'dart.library.io': 'true'},
        environmentComplete: true,
        reason: 'VM test runner',
        sourceConfiguredTarget: mutableSource,
      );
      final condition = BuildCondition.forAuxiliaryTarget(auxiliary);
      final expected = AuxiliaryExecutionTarget(
        id: 'aux:test:vm-widget-source',
        domain: AuxiliaryExecutionDomain.test,
        environmentValues: const {'dart.library.io': 'true'},
        environmentComplete: true,
        reason: 'VM test runner',
        sourceConfiguredTarget: BuildTarget(
          name: 'android-debug',
          platform: 'android',
          flavor: 'debug',
          entrypoint: 'lib/main.dart',
          dartDefines: const {'MODE': 'debug'},
        ),
      );
      final expectedCondition = BuildCondition.forAuxiliaryTarget(expected);
      final hashBeforeMutation = condition.hashCode;

      mutableSource.name = 'android-release';
      sourceDefines['MODE'] = 'release';

      expect(
        condition.applicabilityToAuxiliaryTarget(expected),
        ConditionApplicability.applies,
      );
      expect(condition, expectedCondition);
      expect(condition.hashCode, hashBeforeMutation);
    });

    test('configured and auxiliary exact identities use OR semantics', () {
      final web = BuildTarget(
        name: 'web',
        platform: 'web',
        entrypoint: 'lib/main.dart',
      );
      final condition = BuildCondition(
        exactTargets: {web},
        exactAuxiliaryTargets: {vmTest},
      );

      expect(condition.appliesTo(web), isTrue);
      expect(condition.appliesTo(debug), isFalse);
      expect(
        condition.applicabilityToAuxiliaryTarget(vmTest),
        ConditionApplicability.applies,
      );
      expect(
        condition.applicabilityToAuxiliaryTarget(
          AuxiliaryExecutionTarget(
            id: 'aux:runtime:vm-callback',
            domain: AuxiliaryExecutionDomain.runtime,
            environmentValues: const {'dart.library.io': 'true'},
            environmentComplete: true,
            reason: 'VM callback',
          ),
        ),
        ConditionApplicability.doesNotApply,
      );
    });

    test(
      'auxiliary applicability preserves unknown broad legacy conditions',
      () {
        final legacy = BuildCondition(platforms: const {'android'});

        expect(
          legacy.applicabilityToAuxiliaryTarget(vmTest),
          ConditionApplicability.unknown,
        );
        expect(
          BuildCondition.unconditional.applicabilityToAuxiliaryTarget(vmTest),
          ConditionApplicability.applies,
        );
        expect(
          BuildCondition.forTarget(
            debug,
          ).applicabilityToAuxiliaryTarget(vmTest),
          ConditionApplicability.doesNotApply,
        );
        expect(
          BuildCondition.forAuxiliaryTarget(
            vmTest,
          ).applicabilityToAuxiliaryTarget(vmTest),
          ConditionApplicability.applies,
        );
      },
    );

    test('public execution value types preserve complete value identities', () {
      const callback = CallbackBoundaryDescriptor(
        argumentIndex: 1,
        description: 'native callback',
        capability: CallbackBoundaryCapability.flutterEngineNative,
      );
      const sameCallback = CallbackBoundaryDescriptor(
        argumentIndex: 1,
        description: 'native callback',
        capability: CallbackBoundaryCapability.flutterEngineNative,
      );
      const issue = AuxiliaryExecutionTargetRegistryIssue(
        id: 'aux:runtime:callback',
        acceptedDefinitionSha256: 'accepted',
        rejectedDefinitionSha256: 'rejected',
        reason: 'conflicting target definition',
      );

      expect(callback, sameCallback);
      expect(callback.hashCode, sameCallback.hashCode);
      expect(issue.id, 'aux:runtime:callback');
      expect(issue.reason, 'conflicting target definition');
    });
  });
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

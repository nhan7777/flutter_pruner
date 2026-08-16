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
}

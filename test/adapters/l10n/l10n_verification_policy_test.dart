import 'package:flutter_pruner/src/adapters/l10n/l10n_verification_policy.dart';
import 'package:test/test.dart';

void main() {
  group('L10nVerificationPolicy', () {
    test('has correct default analyze command', () {
      expect(L10nVerificationPolicy.defaultAnalyzeCommand, [
        'analyze',
        '--no-pub',
        '--fatal-infos',
      ]);
    });

    test('has correct default test command', () {
      expect(L10nVerificationPolicy.defaultTestCommand, ['test', '--no-pub']);
    });

    test('hasNoResolutionContract detects --no-pub', () {
      expect(
        L10nVerificationPolicy.hasNoResolutionContract(['analyze', '--no-pub']),
        isTrue,
      );
    });

    test('hasNoResolutionContract detects --no-deps', () {
      expect(
        L10nVerificationPolicy.hasNoResolutionContract(['test', '--no-deps']),
        isTrue,
      );
    });

    test('hasNoResolutionContract returns false when no contract', () {
      expect(
        L10nVerificationPolicy.hasNoResolutionContract(['analyze']),
        isFalse,
      );
    });
  });

  group('validateOverride', () {
    test('accepts default policy', () {
      final result = L10nVerificationPolicy.validateOverride(
        analyzeCommand: L10nVerificationPolicy.defaultAnalyzeCommand,
        testCommand: L10nVerificationPolicy.defaultTestCommand,
      );

      expect(result, VerificationPolicyValidation.accepted);
    });

    test('accepts override with --no-pub in both commands', () {
      final result = L10nVerificationPolicy.validateOverride(
        analyzeCommand: ['analyze', '--no-pub', '--fatal-warnings'],
        testCommand: ['test', '--no-pub', '--coverage'],
      );

      expect(result, VerificationPolicyValidation.accepted);
    });

    test('accepts override with --no-deps in both commands', () {
      final result = L10nVerificationPolicy.validateOverride(
        analyzeCommand: ['analyze', '--no-deps'],
        testCommand: ['test', '--no-deps'],
      );

      expect(result, VerificationPolicyValidation.accepted);
    });

    test('accepts mixed --no-pub and --no-deps', () {
      final result = L10nVerificationPolicy.validateOverride(
        analyzeCommand: ['analyze', '--no-pub'],
        testCommand: ['test', '--no-deps'],
      );

      expect(result, VerificationPolicyValidation.accepted);
    });

    test('rejects override without no-resolution contract in analyze', () {
      final result = L10nVerificationPolicy.validateOverride(
        analyzeCommand: ['analyze', '--fatal-infos'],
        testCommand: ['test', '--no-pub'],
      );

      expect(result, VerificationPolicyValidation.rejectedNoContract);
    });

    test('rejects override without no-resolution contract in test', () {
      final result = L10nVerificationPolicy.validateOverride(
        analyzeCommand: ['analyze', '--no-pub'],
        testCommand: ['test', '--coverage'],
      );

      expect(result, VerificationPolicyValidation.rejectedNoContract);
    });

    test('rejects override without no-resolution contract in both', () {
      final result = L10nVerificationPolicy.validateOverride(
        analyzeCommand: ['analyze'],
        testCommand: ['test'],
      );

      expect(result, VerificationPolicyValidation.rejectedNoContract);
    });

    test('rejects implicit resolution with flutter test alone', () {
      final result = L10nVerificationPolicy.validateOverride(
        analyzeCommand: ['analyze', '--no-pub'],
        testCommand: ['test'],
      );

      expect(result, VerificationPolicyValidation.rejectedNoContract);
    });

    test('rejects explicit pub get requirement in analyze', () {
      final result = L10nVerificationPolicy.validateOverride(
        analyzeCommand: ['pub', 'get', 'analyze'],
        testCommand: ['test', '--no-pub'],
      );

      expect(result, VerificationPolicyValidation.rejectedResolutionRequired);
    });

    test('rejects explicit pub get requirement in test', () {
      final result = L10nVerificationPolicy.validateOverride(
        analyzeCommand: ['analyze', '--no-pub'],
        testCommand: ['pub', 'get', 'test'],
      );

      expect(result, VerificationPolicyValidation.rejectedResolutionRequired);
    });

    test('accepts pub in command when --no-pub is present', () {
      final result = L10nVerificationPolicy.validateOverride(
        analyzeCommand: ['analyze', '--no-pub'],
        testCommand: ['test', '--no-pub'],
      );

      expect(result, VerificationPolicyValidation.accepted);
    });
  });

  group('L10nVerificationPolicy construction', () {
    test('creates policy with flutter binary path', () {
      const policy = L10nVerificationPolicy(
        flutterBinaryPath: '/usr/local/bin/flutter',
      );

      expect(policy.flutterBinaryPath, '/usr/local/bin/flutter');
    });
  });
}
